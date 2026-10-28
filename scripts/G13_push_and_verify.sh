#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G13 (v1) - Push to GitHub + post-publication verification
# Prereq  : 1) empty repo github.com/junlinh12/lattice-enclave-qemu-reproduction
#              (no README/.gitignore/license; Private recommended until reviewed)
#           2) git can authenticate to github.com (e.g. `gh auth login` +
#              `gh auth setup-git`, or an SSH key)
#           3) G12 committed locally (FAIL=0)
# What    :
#   1. every commit's author/committer e-mail is a GitHub noreply address
#   2. set origin (HTTPS) if missing, push main, ls-remote == local HEAD
#   3. fresh clone into work/verify_clone (gitignored) and re-run the leak scan
#      on exactly what GitHub serves; no file outside the allowlist
#   4. report repo visibility (public API: 200 = public, 404 = private)
#   5. commit this gate's log + ledger (after scanning) and push again
# Usage   : bash scripts/G13_push_and_verify.sh
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
LOGDIR="$PROJ/logs"
GATE="G13"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_push_verify_${TS}.log"
LEDGER="$LOGDIR/GATE_LEDGER.md"
OWNER="junlinh12"; REPO="lattice-enclave-qemu-reproduction"
REMOTE_URL="https://github.com/$OWNER/$REPO.git"
CLONE="$PROJ/work/verify_clone"
OKFLAG="$PROJ/work/.g13_ok"; rm -f "$OKFLAG"

cd "$PROJ" || exit 1

# ----------------------------------------------------------------------------- sanitizer
_U="$(id -un)"; _H="$(hostname 2>/dev/null || echo __nohost__)"; _HS="$(hostname -s 2>/dev/null || echo __nohost__)"
sanitize() {
  sed -u -E \
    -e "s#${HOME}#\$HOME#g" -e "s#/home/${_U}#\$HOME#g" \
    -e "s#${_H//./\\.}#<HOST>#g" -e "s#\b${_HS}\b#<HOST>#g" -e "s#\b${_U}\b#<USER>#g" \
    -e 's#\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b#<MAC>#g' \
    -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#<EMAIL>#g' \
    -e 's#\b((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\b#<IPV4>#g'
}
declare -a SUMMARY=()
ok()   { SUMMARY+=("[PASS] $*"); }
warn() { SUMMARY+=("[WARN] $*"); }
fail() { SUMMARY+=("[FAIL] $*"); }
info() { SUMMARY+=("[INFO] $*"); }
sec()  { printf '\n==================== %s ====================\n' "$*"; }
run()  { printf '\n$ %s\n' "$*"; bash -o pipefail -c "$*" 2>&1; local r=$?; printf '(exit=%s)\n' "$r"; return $r; }
finish() {
  sec "SUMMARY"; printf '%s\n' "${SUMMARY[@]}"
  NF=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[FAIL\]'); NW=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[WARN\]')
  echo; echo "RESULT: FAIL=$NF WARN=$NW"
}

# ----------------------------------------------------------------------------- leak scan (same rules as G12 v2)
declare -a TOK=() TOKNAME=()
addtok() { local v="$2" lv; lv=$(echo "$v" | tr 'A-Z' 'a-z')
  [ -n "$v" ] && [ ${#v} -ge 3 ] || return 0
  case "$lv" in root|ubuntu|user|admin|localhost|debian|test|guest|lattice) return 0;; esac
  TOK+=("$v"); TOKNAME+=("$1"); }
addtok "local user name" "$_U"; addtok "host name" "$_H"; addtok "short host name" "$_HS"; addtok "home path" "$HOME"
GEMAIL="$(git config --global user.email 2>/dev/null || true)"; addtok "global git e-mail" "$GEMAIL"
[ "$(echo "${GEMAIL%%@*}" | tr 'A-Z' 'a-z')" != "$OWNER" ] && addtok "global git e-mail local part" "${GEMAIL%%@*}"
GDOM="${GEMAIL#*@}"; addtok "global git e-mail domain" "${GDOM%%.*}"
GECOS="$(getent passwd "$_U" | cut -d: -f5 | cut -d, -f1)"; addtok "account full name" "$GECOS"
GNAME="$(git config --global user.name 2>/dev/null || true)"; [ "$GNAME" != "$OWNER" ] && addtok "global git user.name" "$GNAME"
scan_dir() {  # scan_dir <git work tree> : scans tracked files; returns #FAIL hits
  local d="$1" nfail=0 f i hits wflag
  while IFS= read -r f; do
    f="$d/$f"; [ -s "$f" ] || continue
    grep -Iq . "$f" 2>/dev/null || continue
    for i in "${!TOK[@]}"; do
      wflag=-w; [ "${TOKNAME[$i]}" = "home path" ] && wflag=
      hits=$(grep -F -i -n $wflag -- "${TOK[$i]}" "$f" | cut -d: -f1 | head -5 | tr '\n' ',')
      [ -n "$hits" ] && { echo "  FAIL ${f#$d/}: contains ${TOKNAME[$i]} (lines ${hits%,})"; nfail=$((nfail+1)); }
    done
    grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$f" && { echo "  FAIL ${f#$d/}: private key block"; nfail=$((nfail+1)); }
    grep -qE '\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b' "$f" && { echo "  FAIL ${f#$d/}: MAC address"; nfail=$((nfail+1)); }
    hits=$(grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$f" | grep -viE '@users\.noreply\.github\.com|@example\.(com|org|invalid)' | head -1)
    [ -n "$hits" ] && { echo "  FAIL ${f#$d/}: e-mail address"; nfail=$((nfail+1)); }
  done < <(git -C "$d" ls-files)
  echo "scan($d -> $(git -C "$d" ls-files | wc -l) files): fail_hits=$nfail"
  return $nfail
}

main() {
  sec "META"; echo "gate=$GATE (v1) timestamp_utc=$TS target=$OWNER/$REPO"

  # --------------------------------------------------------------------------- 1. commit identities
  sec "1. Commit identities"
  run "git log --format='%h %an <%ae> | %cn <%ce> | %ad' --date=iso-strict"
  local bad; bad=$(git log --format='%ae%n%ce' | grep -viE '@users\.noreply\.github\.com$' | sort -u)
  [ -z "$bad" ] && ok "all author/committer e-mails are GitHub noreply" || { fail "non-noreply e-mail in history - not pushing"; finish; return; }
  git log --format='%ad' --date=iso-strict | grep -qv '+00:00$' && warn "some commit dates are not UTC" || ok "all commit dates in UTC"
  [ -z "$(git status --porcelain)" ] && ok "working tree clean" || { run "git status --short"; warn "uncommitted changes (only committed content is pushed)"; }

  # --------------------------------------------------------------------------- 2. push
  sec "2. Remote + push"
  if ! git remote get-url origin >/dev/null 2>&1; then run "git remote add origin $REMOTE_URL"; fi
  run "git remote -v"
  case "$(git remote get-url origin)" in *"$OWNER/$REPO"*) ok "origin points to $OWNER/$REPO";; *) fail "origin is not $OWNER/$REPO"; finish; return;; esac
  if run "git push -u origin main"; then ok "pushed main"; else fail "git push failed (auth? repo not created? e-mail blocked?)"; finish; return; fi
  local lh rh; lh=$(git rev-parse HEAD); rh=$(git ls-remote origin refs/heads/main | cut -f1)
  echo "local=$lh remote=$rh"
  [ "$lh" = "$rh" ] && ok "remote main == local HEAD" || fail "remote main differs from local HEAD"

  # --------------------------------------------------------------------------- 3. verify clone
  sec "3. Fresh clone + leak scan of what GitHub serves"
  rm -rf "$CLONE"
  if run "git clone -q $REMOTE_URL '$CLONE'"; then ok "fresh clone OK"; else fail "clone failed"; finish; return; fi
  run "git -C '$CLONE' ls-files | cut -d/ -f1 | sort | uniq -c"
  if git -C "$CLONE" ls-files | grep -qvE '^(\.gitignore|README\.md|env\.sh|fw_params\.env|SOURCES_PINNED\.txt|docs/|scripts/|patches/|tests/|logs/)'; then
    fail "clone contains files outside the allowlist"; git -C "$CLONE" ls-files | grep -vE '^(\.gitignore|README\.md|env\.sh|fw_params\.env|SOURCES_PINNED\.txt|docs/|scripts/|patches/|tests/|logs/)'
  else ok "clone contains only allowlisted paths"; fi
  git -C "$CLONE" ls-files | grep -qE 'GATE0|^work/|^sources/|_raw\.log$' && fail "forbidden artifact in clone" || ok "no GATE0/raw/work/sources artifacts in clone"
  if scan_dir "$CLONE"; then ok "leak scan of published content: clean"; else fail "leak scan of published content found issues - make repo private / fix immediately"; fi

  # --------------------------------------------------------------------------- 4. visibility
  sec "4. Visibility"
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' "https://api.github.com/repos/$OWNER/$REPO")
  echo "unauthenticated GitHub API status: $code"
  case "$code" in 200) info "repository is PUBLIC";; 404) info "repository is PRIVATE (switch to public after reviewing on github.com)";; *) warn "could not determine visibility (HTTP $code)";; esac

  if ! printf '%s\n' "${SUMMARY[@]}" | grep -q '^\[FAIL\]'; then touch "$OKFLAG"; fi
  finish
}

main 2>&1 | sanitize | tee "$LOG"
RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')
echo "| $GATE | Push to GitHub + verify published content | $TS | ${RES:-ABORTED} | $(basename "$LOG") | - |" >> "$LEDGER"

# ----------------------------------------------------------------------------- 5. record this gate
if [ -f "$OKFLAG" ]; then
  rm -f "$OKFLAG"
  echo; echo "==== scan + commit + push of G13 log and ledger ===="
  git add -A
  if scan_dir "$PROJ"; then
    TZ=UTC GIT_AUTHOR_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" GIT_COMMITTER_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      git commit -q -m "G13: push verification log" && git push -q origin main \
      && { echo ">>> pushed:"; git log --oneline -2; }
  else
    git reset -q
    echo ">>> scan of new files failed - G13 log not committed (unstaged again)"
  fi
fi
echo; echo ">>> Log: logs/$(basename "$LOG") - please upload it."
