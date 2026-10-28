#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G12 (v2) - Sanitization audit + local git commit (NO push)
# What    :
#   1. Allowlist .gitignore: only README.md, docs/, scripts/, patches/, tests/,
#      logs/, env.sh, fw_params.env, SOURCES_PINNED.txt can be committed.
#      Previous-attempt artifacts (scripts/GATE0*, logs/GATE0*, hidden files
#      in logs/) and sources/, work/, tools/ are never committed.
#   2. git init (branch main), repo-local identity = GitHub noreply address.
#   3. Leak scan of every file that would be committed:
#        FAIL : local user name, host name (long/short), home path, global git
#               e-mail (+ local part / domain), GECOS name, private-key blocks,
#               MAC addresses, non-allowlisted e-mail addresses
#        WARN : IPv4 literals other than 127.0.0.1 / 0.0.0.0, files > 5 MB
#        INFO : host hardware details (CPU model, disk layout) in G01 log
#      The secret values themselves are never printed.
#   4. If FAIL=0: append ledger row, re-scan, commit with TZ=UTC (no local
#      time-zone leak). Pushing is a separate, manual step (G13).
# Prereq  : README.md -> project root, REPORT.md -> docs/REPORT.md
# Usage   : bash scripts/G12_sanitize_and_commit.sh
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
LOGDIR="$PROJ/logs"
GATE="G12"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_publish_audit_${TS}.log"
LEDGER="$LOGDIR/GATE_LEDGER.md"
OKFLAG="$(mktemp)"; rm -f "$OKFLAG"
PUB_NAME="junlinh12"                                  # GitHub account
PUB_EMAIL="238169016+junlinh12@users.noreply.github.com"   # GitHub noreply (ID+name)

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

# ----------------------------------------------------------------------------- secret tokens (never printed)
declare -a TOK=() TOKNAME=()
# generic words are skipped (they would match "rootfs", "ubuntu" guest user, ...)
addtok() { local v="$2" lv; lv=$(echo "$v" | tr 'A-Z' 'a-z')
  [ -n "$v" ] && [ ${#v} -ge 3 ] || return 0
  case "$lv" in root|ubuntu|user|admin|localhost|debian|test|guest|lattice) return 0;; esac
  TOK+=("$v"); TOKNAME+=("$1"); }
addtok "local user name" "$_U"
addtok "host name" "$_H"
addtok "short host name" "$_HS"
addtok "home path" "$HOME"
GEMAIL="$(git config --global user.email 2>/dev/null || true)"
addtok "global git e-mail" "$GEMAIL"
# v2: the e-mail local part equals the public GitHub account name -> not secret
[ "$(echo "${GEMAIL%%@*}" | tr 'A-Z' 'a-z')" != "$(echo "$PUB_NAME" | tr 'A-Z' 'a-z')" ] && addtok "global git e-mail local part" "${GEMAIL%%@*}"
GDOM="${GEMAIL#*@}"; addtok "global git e-mail domain" "${GDOM%%.*}"
GECOS="$(getent passwd "$_U" | cut -d: -f5 | cut -d, -f1)"; addtok "account full name" "$GECOS"
GNAME="$(git config --global user.name 2>/dev/null || true)"; [ "$GNAME" != "$PUB_NAME" ] && addtok "global git user.name" "$GNAME"

# scan_files <file...> : prints findings (secret values masked), returns #FAIL hits
scan_files() {
  local nfail=0 nwarn=0 f i hits
  for f in "$@"; do
    [ -f "$f" ] || continue
    [ -s "$f" ] || continue                       # empty file
    grep -Iq . "$f" 2>/dev/null || { echo "  (binary, skipped text scan) $f"; continue; }
    for i in "${!TOK[@]}"; do
      local wflag=-w; [ "${TOKNAME[$i]}" = "home path" ] && wflag=
      hits=$(grep -F -i -n $wflag -- "${TOK[$i]}" "$f" | cut -d: -f1 | head -5 | tr '\n' ',')
      [ -n "$hits" ] && { echo "  FAIL $f: contains ${TOKNAME[$i]} (lines ${hits%,})"; nfail=$((nfail+1)); }
    done
    if grep -nE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$f" >/dev/null; then echo "  FAIL $f: private key block"; nfail=$((nfail+1)); fi
    hits=$(grep -noE '\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b' "$f" | head -3 | cut -d: -f1 | tr '\n' ',')
    [ -n "$hits" ] && { echo "  FAIL $f: MAC address (lines ${hits%,})"; nfail=$((nfail+1)); }
    hits=$(grep -noE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$f" \
           | grep -viE '@users\.noreply\.github\.com|@example\.(com|org|invalid)' | head -3 | cut -d: -f1 | tr '\n' ',')
    [ -n "$hits" ] && { echo "  FAIL $f: e-mail address (lines ${hits%,})"; nfail=$((nfail+1)); }
    hits=$(grep -noE '\b((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\b' "$f" \
           | grep -vE ':(127\.0\.0\.1|0\.0\.0\.0)$' | head -3)
    [ -n "$hits" ] && { echo "  WARN $f: IPv4-like literal(s): $(echo "$hits" | tr '\n' ' ')"; nwarn=$((nwarn+1)); }
  done
  echo "scan: files=$# fail_hits=$nfail warn_hits=$nwarn"
  SCAN_WARN=$nwarn
  return $nfail
}

write_gitignore() {
  cat > .gitignore <<'EOF'
# Allowlist: everything is ignored unless explicitly listed below.
/*
!/.gitignore
!/README.md
!/docs/
!/scripts/
!/patches/
!/tests/
!/logs/
!/env.sh
!/fw_params.env
!/SOURCES_PINNED.txt
# Never publish: artifacts of an earlier, unsanitized attempt
/scripts/GATE0*
/logs/GATE0*
/logs/.*
/logs/*_raw.log
# build outputs inside allowed dirs
/tests/**/*.o
EOF
}

main() {
  sec "META"; echo "gate=$GATE (v2) timestamp_utc=$TS publish_identity=$PUB_NAME <$PUB_EMAIL>"
  echo "secret tokens loaded for scanning: ${#TOK[@]} (values not shown)"

  sec "1. Prerequisites"
  [ -f README.md ] && ok "README.md present" || fail "README.md missing (copy it to the project root)"
  [ -f docs/REPORT.md ] && ok "docs/REPORT.md present" || fail "docs/REPORT.md missing (mkdir -p docs; copy REPORT.md)"
  [ -f logs/GATE_LEDGER.md ] && ok "ledger present" || fail "ledger missing"
  if printf '%s\n' "${SUMMARY[@]}" | grep -q '^\[FAIL\]'; then finish; return; fi

  sec "2. Allowlist .gitignore + git init"
  [ -f .gitignore ] && cp .gitignore "work/.gitignore.before_G12" 2>/dev/null
  write_gitignore; run "cat .gitignore"
  if [ ! -d .git ]; then run "git init -q -b main ." && ok "git repository initialised (main)"; else ok "git repository exists"; fi
  git config user.name "$PUB_NAME"; git config user.email "$PUB_EMAIL"; git config commit.gpgsign false
  ok "repo-local identity set to GitHub noreply"

  sec "3. Files that would be committed"
  mapfile -t FILES < <(git ls-files -co --exclude-standard | sort)
  printf '%s\n' "${FILES[@]}"
  echo "count=${#FILES[@]}  total=$(du -ch "${FILES[@]}" 2>/dev/null | tail -1 | cut -f1)"
  printf '%s\n' "${FILES[@]}" | grep -qE '^(sources|work|tools)/|GATE0|/\.gate' && fail "forbidden path in candidate list" || ok "no sources/work/tools/GATE0 artifacts in candidate list"
  local big; big=$(for f in "${FILES[@]}"; do [ "$(stat -c %s "$f")" -gt 5000000 ] && echo "$f"; done)
  [ -n "$big" ] && { echo "large files:"; echo "$big"; warn "files > 5 MB present"; } || ok "no file > 5 MB"

  sec "4. Leak scan"
  SCAN_WARN=0
  if scan_files "${FILES[@]}"; then ok "no secret token / key / MAC / e-mail found"; else fail "leak scan found issues (see above) - nothing committed"; fi
  [ "${SCAN_WARN:-0}" -gt 0 ] && warn "IPv4-like literals present (review list above; version numbers can match)"
  if grep -lE 'Model name|nvme|/dev/sd[a-z]' logs/G01_*.log >/dev/null 2>&1; then
    info "G01 log contains host hardware details (CPU model, disk device/usage). Not personal; kept for reproducibility. Tell Claude if you want them masked."
  fi
  if ! printf '%s\n' "${SUMMARY[@]}" | grep -q '^\[FAIL\]'; then touch "$OKFLAG"; fi
  finish
}

main 2>&1 | sanitize | tee "$LOG"
RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')
echo "| $GATE | Sanitization audit + local commit | $TS | ${RES:-ABORTED} | $(basename "$LOG") | - |" >> "$LEDGER"

if [ -f "$OKFLAG" ]; then
  rm -f "$OKFLAG"
  echo; echo "==== final re-scan (includes this gate's log and ledger) ===="
  mapfile -t FILES < <(git ls-files -co --exclude-standard | sort)
  if scan_files "${FILES[@]}"; then
    git add -A
    TZ=UTC GIT_AUTHOR_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" GIT_COMMITTER_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      git commit -q -m "Lattice QEMU reproduction: gates G01-G12, patches 0001-0003, logs and report" \
      && { echo ">>> committed locally (not pushed):"; git log --oneline -1; git show --stat --format= HEAD | tail -3; }
  else
    echo ">>> final re-scan failed - nothing committed"
  fi
else
  echo; echo ">>> audit not clean - nothing committed. Fix the FAIL items and re-run."
fi
echo; echo ">>> Log: logs/$(basename "$LOG")  - please upload it."
echo ">>> Next (G13): create the empty GitHub repo and push - instructions will follow."
