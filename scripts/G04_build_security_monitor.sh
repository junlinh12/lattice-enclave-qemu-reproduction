#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G04 - Build the Lattice security monitor (SM, platform/qemu-virt)
# What    : Runs ONLY the "sm" target of platform/qemu-virt/firmware.mk
#           (cargo build + objcopy -> build/qemu-virt/sm.bin) for debug and
#           release, then verifies the ELF / binary. OpenSBI & U-Boot are G05.
# Usage   : bash scripts/G04_build_security_monitor.sh
# Writes  : work/Lattice/target/, work/Lattice/build/qemu-virt/sm.bin
#           work/artifacts/sm-{debug,release}/   (copies + sha256)
#           logs/G04_build_sm_<UTC>.log, logs/GATE_LEDGER.md
# Safety  : No network needed (crates were fetched at G03, build uses --locked
#           semantics via a lockfile-unchanged check). sources/ untouched.
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
WORK="$PROJ/work/Lattice"
PLAT="$WORK/platform/qemu-virt"
BUILD="$WORK/build/qemu-virt"
ART="$PROJ/work/artifacts"
LOGDIR="$PROJ/logs"
GATE="G04"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_build_sm_${TS}.log"
LEDGER="$LOGDIR/GATE_LEDGER.md"
# Values from firmware.mk (kept identical to upstream defaults)
SM_TEXT_START="0x8001e000"; FW_TEXT_START="0x80000000"; PMP_COUNT="16"
ELF_TGT="riscv64imac-unknown-none-elf"

mkdir -p "$LOGDIR" "$ART"

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
run()  { printf '\n$ %s\n' "$*"; bash -o pipefail -c "$*" 2>&1; local r=$?; printf '(exit=%s)\n' "$r"; return $r; }

build_profile() {
  local profile="$1" t0 t1 elf bin out
  sec "Build SM: profile=$profile"
  t0=$(date +%s)
  # Same invocation as `make debug|release` minus the opensbi part.
  # Full compiler output goes to a per-profile build log in logs/ (the vendored
  # riscv crate alone emits ~940 benign "unexpected cfg" warnings).
  local blog="$LOGDIR/${GATE}_build_sm_${TS}_cargo_${profile}.log"
  echo "full cargo output -> logs/$(basename "$blog")"
  ( cd "$WORK" && mkdir -p "$BUILD" && CARGO_NET_OFFLINE=true make -f "$PLAT/firmware.mk" \
        build_path="$BUILD" platform_path="$PLAT" profile=$profile \
        SM_TEXT_START=$SM_TEXT_START FW_TEXT_START=$FW_TEXT_START PMP_COUNT=$PMP_COUNT sm ) 2>&1 | sanitize > "$blog"
  local rc=${PIPESTATUS[0]}
  echo "make exit=$rc"
  grep -E '^\s+Finished|^error' "$blog"
  echo "warning tally:"; grep -E '^warning: ' "$blog" | sed -E 's/`[^`]*`/X/g' | sort | uniq -c | sort -rn | head -8
  t1=$(date +%s); echo "build_time_sec=$((t1-t0))"
  if [ $rc -ne 0 ]; then fail "SM build ($profile)"; return 1; fi
  ok "SM build ($profile) in $((t1-t0)) s"

  elf="$WORK/target/$ELF_TGT/$profile/qemu-virt"; bin="$BUILD/sm.bin"
  sec "Verify SM artifacts: $profile"
  [ -f "$elf" ] && ok "ELF exists ($profile)" || { fail "ELF missing ($profile)"; return 1; }
  run "file '$elf'"
  run "riscv64-unknown-linux-gnu-readelf -h '$elf' | grep -E 'Class|Machine|Entry|Flags'"
  run "riscv64-unknown-linux-gnu-readelf -SW '$elf' | grep -E '^\s+\[' "
  run "riscv64-unknown-linux-gnu-size -A '$elf'"

  local entry text_addr
  entry=$(riscv64-unknown-linux-gnu-readelf -h "$elf" | awk '/Entry point/ {print $4}')
  # "[ 1] .text ..." splits into two fields, so locate ".text" by value, not by column
  text_addr=$(riscv64-unknown-linux-gnu-readelf -SW "$elf" | awk '{for(i=1;i<=NF;i++) if($i==".text"){print "0x"$(i+2); exit}}')
  echo "entry=$entry  .text=$text_addr  expected=$SM_TEXT_START"
  [ "$((entry))" -eq "$((SM_TEXT_START))" ] && ok "entry point == SM_TEXT_START ($profile)" \
                                            || warn "entry point $entry != SM_TEXT_START ($profile)"
  [ "$((text_addr))" -eq "$((SM_TEXT_START))" ] && ok ".text starts at SM_TEXT_START ($profile)" \
                                                || fail ".text at $text_addr != $SM_TEXT_START ($profile)"
  riscv64-unknown-linux-gnu-readelf -h "$elf" | grep -q 'RISC-V' && ok "ELF machine is RISC-V ($profile)" || fail "ELF machine ($profile)"

  [ -s "$bin" ] && ok "sm.bin produced ($profile, $(stat -c %s "$bin") bytes)" || { fail "sm.bin missing ($profile)"; return 1; }
  run "riscv64-unknown-linux-gnu-objdump -d --start-address=$SM_TEXT_START --stop-address=$((SM_TEXT_START+32)) '$elf' | tail -n +7"

  out="$ART/sm-$profile"; mkdir -p "$out"
  cp -f "$elf" "$out/qemu-virt.elf"; cp -f "$bin" "$out/sm.bin"
  ( cd "$out" && sha256sum qemu-virt.elf sm.bin > SHA256SUMS )
  run "cat '$out/SHA256SUMS'"
}

main() {
  sec "META"
  echo "gate=$GATE timestamp_utc=$TS SM_TEXT_START=$SM_TEXT_START FW_TEXT_START=$FW_TEXT_START PMP_COUNT=$PMP_COUNT"
  # shellcheck disable=SC1091
  source "$PROJ/env.sh" || { fail "env.sh missing (run G03)"; return; }
  run "git -C '$WORK' log --oneline -3"
  run "cd '$WORK' && rustc -V && cargo -V"
  [ -z "$(git -C "$WORK" status --porcelain)" ] && ok "work tree clean before build" || warn "work tree has local changes before build"

  build_profile debug
  build_profile release      # built last: build/qemu-virt/sm.bin == release

  sec "Lockfile integrity"
  if git -C "$WORK" diff --quiet -- Cargo.lock; then ok "Cargo.lock unchanged by build"
  else run "git -C '$WORK' diff --stat -- Cargo.lock"; fail "Cargo.lock modified by build"; fi

  sec "Disk usage"
  run "du -sh '$WORK/target' '$BUILD' 2>/dev/null"

  sec "SUMMARY"
  printf '%s\n' "${SUMMARY[@]}"
  NF=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[FAIL\]'); NW=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[WARN\]')
  echo; echo "RESULT: FAIL=$NF WARN=$NW"
}

main 2>&1 | sanitize | tee "$LOG"
RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')
echo "| $GATE | Build security monitor (debug+release) | $TS | ${RES:-ABORTED} | $(basename "$LOG") | - |" >> "$LEDGER"
echo
echo ">>> Log written: logs/$(basename "$LOG")"; echo ">>> Please upload that log file to the chat."
