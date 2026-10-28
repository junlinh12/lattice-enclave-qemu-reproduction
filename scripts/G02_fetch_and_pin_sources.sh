#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G02 - Fetch upstream sources and pin exact commits
# Usage   : bash scripts/G02_fetch_and_pin_sources.sh
# Writes  : $PROJ/sources/{Lattice,opensbi,u-boot}   (pristine upstream clones)
#           $PROJ/SOURCES_PINNED.txt                 (pin manifest, publishable)
#           $PROJ/logs/G02_fetch_pin_<UTC>.log       (sanitized)
#           $PROJ/logs/GATE_LEDGER.md                (appended)
#           $PROJ/.gitignore                         (adds "sources/" if absent)
# Safety  : Never overwrites an existing clone. If a target dir exists at a
#           different commit, the gate stops with FAIL and changes nothing.
#           Prior work under ~/Lattice is only read, never modified.
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
SRC="$PROJ/sources"
LOGDIR="$PROJ/logs"
GATE="G02"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_fetch_pin_${TS}.log"
LEDGER="$LOGDIR/GATE_LEDGER.md"
PIN="$PROJ/SOURCES_PINNED.txt"
PRIOR_SRC="$HOME/Lattice/Lattice-Reproduction-V1/source/Lattice"

LATTICE_URL="https://github.com/LatticeEnclave/Lattice.git"
LATTICE_COMMIT="05664a26af63e0898828a37b4387efc188388dbf"   # upstream main HEAD (2025-05-26)
OPENSBI_URL="https://github.com/riscv-software-src/opensbi.git"
OPENSBI_COMMIT="ef4520b1c63fc2770b10d952a800f9734f861b0a"   # pinned in platform/qemu-virt/firmware.mk
UBOOT_URL="https://github.com/u-boot/u-boot.git"
UBOOT_TAG="v2024.10"   # NOT specified upstream; chosen as contemporaneous with
                       # OpenSBI ef4520b (2024-08) and rust nightly-2024-11-27

mkdir -p "$LOGDIR" "$SRC"

# ----------------------------------------------------------------------------- sanitizer
_U="$(id -un)"; _H="$(hostname 2>/dev/null || echo __nohost__)"; _HS="$(hostname -s 2>/dev/null || echo __nohost__)"
sanitize() {
  sed -E \
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
sec()  { printf '\n==================== %s ====================\n' "$*"; }
run()  { printf '\n$ %s\n' "$*"; bash -c "$*" 2>&1; local r=$?; printf '(exit=%s)\n' "$r"; return $r; }

# clone_pinned <name> <url> <commit-or-tag> <mode: commit|tag>
clone_pinned() {
  local name="$1" url="$2" ref="$3" mode="$4" dir="$SRC/$1" want head
  sec "Fetch: $name @ $ref"
  if [ -d "$dir/.git" ]; then
    head=$(git -C "$dir" rev-parse HEAD)
    if [ "$mode" = tag ]; then want=$(git -C "$dir" rev-parse "refs/tags/$ref^{commit}" 2>/dev/null); else want="$ref"; fi
    if [ -n "$want" ] && [ "$head" = "$want" ]; then
      echo "already present at $head -> skip clone"; ok "$name present at pinned ref"
    else
      echo "EXISTS at $head but expected $ref -> not touching it"; fail "$name: existing clone at unexpected commit"; return 1
    fi
  elif [ -e "$dir" ]; then
    echo "path exists but is not a git repo: $dir"; fail "$name: target path occupied"; return 1
  else
    if [ "$mode" = tag ]; then
      run "git clone --depth 1 --branch '$ref' '$url' '$dir'" || { fail "$name clone"; return 1; }
    else
      run "git clone '$url' '$dir'" || { fail "$name clone"; return 1; }
      run "git -C '$dir' -c advice.detachedHead=false checkout '$ref'" || { fail "$name checkout"; return 1; }
    fi
  fi
  run "git -C '$dir' log -1 --format='HEAD=%H%ncommit_date=%cI%nsubject=%s'"
  run "git -C '$dir' status --short | wc -l"
  if [ -n "$(git -C "$dir" status --porcelain)" ]; then fail "$name working tree not clean"; else ok "$name working tree clean"; fi
  if [ "$mode" = commit ]; then
    [ "$(git -C "$dir" rev-parse HEAD)" = "$ref" ] && ok "$name HEAD == $ref" || fail "$name HEAD mismatch"
  fi
}

main() {
  sec "META"
  echo "gate=$GATE timestamp_utc=$TS"
  run "git --version"

  clone_pinned Lattice "$LATTICE_URL" "$LATTICE_COMMIT" commit
  clone_pinned opensbi "$OPENSBI_URL" "$OPENSBI_COMMIT" commit
  clone_pinned u-boot  "$UBOOT_URL"   "$UBOOT_TAG"      tag

  # --------------------------------------------------------------------------- static checks
  sec "Static checks on Lattice tree"
  L="$SRC/Lattice"
  if [ -d "$L" ]; then
    run "ls -1A '$L'"
    run "cat '$L/rust-toolchain.toml'"
    run "grep -n 'opensbi_commit' '$L/platform/qemu-virt/firmware.mk'"
    grep -q "$OPENSBI_COMMIT" "$L/platform/qemu-virt/firmware.mk" && ok "firmware.mk pins OpenSBI $OPENSBI_COMMIT" || fail "firmware.mk OpenSBI pin differs"
    # workspace members that do not exist -> expected cargo failure at G04
    sec "Workspace member existence"
    for m in tests runtime crates platform; do
      if [ -e "$L/$m" ]; then echo "present: $m"; else echo "MISSING: $m"; warn "Cargo workspace member '$m' does not exist in upstream tree (fix needed at G04)"; fi
    done
    [ -f "$L/Cargo.lock" ] && ok "Cargo.lock present" || warn "No Cargo.lock upstream: crate versions float (lockfile to be generated & recorded at G04)"
  fi

  sec "OpenSBI patch applicability (check only, no change)"
  if [ -d "$SRC/opensbi" ] && [ -f "$L/platform/qemu-virt/qemu.patch" ]; then
    if run "git -C '$SRC/opensbi' apply --check --verbose '$L/platform/qemu-virt/qemu.patch'"; then ok "qemu.patch applies cleanly to OpenSBI $OPENSBI_COMMIT"
    else fail "qemu.patch does not apply"; fi
  fi

  sec "U-Boot defconfig used by firmware.mk"
  if [ -f "$SRC/u-boot/configs/qemu-riscv64_smode_defconfig" ]; then echo "found configs/qemu-riscv64_smode_defconfig"; ok "u-boot $UBOOT_TAG has qemu-riscv64_smode_defconfig"
  else fail "qemu-riscv64_smode_defconfig not found in u-boot $UBOOT_TAG"; fi

  # --------------------------------------------------------------------------- prior work (read-only)
  sec "Prior Lattice source (READ-ONLY comparison with upstream)"
  if [ -d "$PRIOR_SRC/.git" ]; then
    run "git -C '$PRIOR_SRC' log --format='%h %cI %s' -n 15"
    run "git -C '$PRIOR_SRC' remote -v | sed -E 's#://[^@/]+@#://<CRED>@#'"
    if git -C "$PRIOR_SRC" cat-file -e "${LATTICE_COMMIT}^{commit}" 2>/dev/null; then
      echo "upstream commit is an ancestor candidate in prior repo"
      run "git -C '$PRIOR_SRC' merge-base --is-ancestor $LATTICE_COMMIT HEAD && echo 'prior HEAD = upstream + local commits'"
      run "git -C '$PRIOR_SRC' log --format='%h %s' $LATTICE_COMMIT..HEAD"
      run "git -C '$PRIOR_SRC' diff --stat $LATTICE_COMMIT HEAD"
    else
      echo "upstream commit $LATTICE_COMMIT NOT found in prior repo"
      if [ -d "$L/.git" ]; then
        run "git -C '$L' fetch -q '$PRIOR_SRC' HEAD:refs/prior/head 2>&1 && git -C '$L' diff --stat $LATTICE_COMMIT refs/prior/head | tail -25; git -C '$L' update-ref -d refs/prior/head"
      fi
    fi
    warn "prior source is a locally modified tree; used as reference only"
  else
    echo "prior source not found (ok)"
  fi

  # --------------------------------------------------------------------------- disk
  sec "Disk usage"
  run "du -sh '$SRC'/* 2>/dev/null"

  sec "SUMMARY"
  printf '%s\n' "${SUMMARY[@]}"
  NF=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[FAIL\]')
  NW=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[WARN\]')
  echo; echo "RESULT: FAIL=$NF WARN=$NW"
}

main 2>&1 | sanitize | tee "$LOG"
RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')

# ----------------------------------------------------------------------------- pin manifest (only on FAIL=0)
if echo "$RES" | grep -q '^FAIL=0'; then
  {
    echo "# Pinned upstream sources - lattice-enclave-qemu-reproduction"
    echo "# generated by G02 at $TS (UTC)"
    for n in Lattice opensbi u-boot; do
      d="$SRC/$n"
      printf '%-8s %s  %s  (%s)\n' "$n" "$(git -C "$d" rev-parse HEAD)" \
        "$(git -C "$d" remote get-url origin)" "$(git -C "$d" log -1 --format=%cs)"
    done
    echo "u-boot tag: $UBOOT_TAG (chosen by this reproduction; upstream Lattice does not specify)"
    echo "rust toolchain: nightly-2024-11-27 (from rust-toolchain.toml)"
  } > "$PIN"
  echo ">>> Pin manifest written: SOURCES_PINNED.txt"
fi

# ----------------------------------------------------------------------------- .gitignore
touch "$PROJ/.gitignore"
grep -qxF 'sources/' "$PROJ/.gitignore" || { echo 'sources/' >> "$PROJ/.gitignore"; echo ">>> added 'sources/' to .gitignore"; }

# ----------------------------------------------------------------------------- ledger
echo "| $GATE | Fetch & pin sources | $TS | $RES | $(basename "$LOG") | - |" >> "$LEDGER"
echo
echo ">>> Log written: logs/$(basename "$LOG")"
echo ">>> Please upload that log file to the chat."
