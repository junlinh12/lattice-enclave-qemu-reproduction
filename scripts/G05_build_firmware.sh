#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G05 - Build OpenSBI(+Lattice SM) + U-Boot -> fw_payload.bin   [CHECKPOINT]
# What    :
#   0. CHECKPOINT: re-read ~/projects/MAIN_TASK.md into the log (R3)
#   1. Stage pinned local sources into build/qemu-virt/{opensbi,u-boot}
#      (replaces firmware.mk's network clone; same commit + same qemu.patch)
#   2. Build U-Boot (qemu-riscv64_smode_defconfig) in parallel
#   3. Run upstream `firmware.mk ... profile=release firmware` (sm + opensbi)
#   4. Verify: sm_init address == SM_TEXT_START, embedded .sm == sm.bin,
#      SM ends before the U-Boot payload. If OpenSBI placed .sm elsewhere
#      (compiler-dependent text size), rebuild once with the actual address.
#   5. 30 s QEMU smoke test (firmware only, no disk): OpenSBI -> SM -> U-Boot
# Usage   : bash scripts/G05_build_firmware.sh
# Writes  : work/Lattice/build/qemu-virt/*, work/artifacts/fw-release/,
#           fw_params.env, logs/G05_*.log, logs/GATE_LEDGER.md
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
WORK="$PROJ/work/Lattice"
PLAT="$WORK/platform/qemu-virt"
BUILD="$WORK/build/qemu-virt"
OSBI="$BUILD/opensbi"
UBOOT="$BUILD/u-boot"
ART="$PROJ/work/artifacts/fw-release"
LOGDIR="$PROJ/logs"
GATE="G05"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_build_fw_${TS}.log"
LEDGER="$LOGDIR/GATE_LEDGER.md"
MAIN_TASK="$HOME/projects/MAIN_TASK.md"
OPENSBI_COMMIT="ef4520b1c63fc2770b10d952a800f9734f861b0a"
UBOOT_COMMIT="f919c3a889f0ec7d63a48b5d0ed064386b0980bd"   # v2024.10
SM_TEXT_START="0x8001e000"; FW_TEXT_START="0x80000000"; PMP_COUNT="16"
NPROC="$(nproc)"
FW_ELF="$OSBI/build/platform/generic/firmware/fw_payload.elf"

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
# runlog <tag> <cmd>: full output -> logs/G05_..._<tag>.log, tail -> main log
runlog() {
  local tag="$1"; shift
  local f="$LOGDIR/${GATE}_build_fw_${TS}_${tag}.log"
  printf '\n$ %s\n(full output -> logs/%s)\n' "$*" "$(basename "$f")"
  bash -o pipefail -c "$*" 2>&1 | sanitize > "$f"; local r=${PIPESTATUS[0]}
  tail -n 15 "$f"; printf '(exit=%s)\n' "$r"; return $r
}
hex() { printf '0x%x' "$(( $1 ))"; }
sym() { riscv64-unknown-linux-gnu-nm "$FW_ELF" 2>/dev/null | awk -v s="$1" '$3==s {print "0x"$1; exit}'; }

stage_sources() {
  sec "1. Stage pinned sources into build/qemu-virt"
  mkdir -p "$BUILD"
  # OpenSBI: identical to firmware.mk's rule (clone, checkout pin, git apply qemu.patch) but from local mirror
  if [ -d "$OSBI/.git" ]; then
    [ "$(git -C "$OSBI" rev-parse HEAD)" = "$OPENSBI_COMMIT" ] && ok "opensbi already staged at pin" || { fail "build/opensbi at unexpected commit"; return 1; }
    git -C "$OSBI" apply --reverse --check "$PLAT/qemu.patch" 2>/dev/null && ok "qemu.patch already applied" || { fail "build/opensbi exists without qemu.patch"; return 1; }
  else
    run "git clone -q '$PROJ/sources/opensbi' '$OSBI' && git -C '$OSBI' -c advice.detachedHead=false checkout -q $OPENSBI_COMMIT && git -C '$OSBI' apply '$PLAT/qemu.patch'" \
      && ok "opensbi staged + qemu.patch applied" || { fail "stage opensbi"; return 1; }
  fi
  run "git -C '$OSBI' status --short"
  # U-Boot
  if [ -d "$UBOOT/.git" ]; then
    [ "$(git -C "$UBOOT" rev-parse HEAD)" = "$UBOOT_COMMIT" ] && ok "u-boot already staged at v2024.10" || { fail "build/u-boot at unexpected commit"; return 1; }
  else
    run "git clone -q '$PROJ/sources/u-boot' '$UBOOT'" && ok "u-boot staged (v2024.10)" || { fail "stage u-boot"; return 1; }
  fi
  # Upstream bug workaround: the opensbi recipe starts with an unguarded
  # `rm -r build/platform/generic/firmware/`, which fails on a first build.
  mkdir -p "$OSBI/build/platform/generic/firmware"
  echo "pre-created opensbi build/platform/generic/firmware/ (upstream rm -r workaround)"
}

build_uboot() {
  sec "2. Build U-Boot (same commands as firmware.mk, parallel)"
  if [ -s "$UBOOT/u-boot.bin" ]; then echo "u-boot.bin exists -> skip"; ok "u-boot.bin present"; return 0; fi
  local t0=$(date +%s)
  runlog uboot "cd '$UBOOT' && make CROSS_COMPILE=riscv64-unknown-linux-gnu- qemu-riscv64_smode_defconfig && make -j$NPROC CROSS_COMPILE=riscv64-unknown-linux-gnu-" \
    || { fail "u-boot build"; return 1; }
  echo "uboot_build_time_sec=$(( $(date +%s)-t0 ))"
  [ -s "$UBOOT/u-boot.bin" ] && ok "u-boot.bin built ($(stat -c %s "$UBOOT/u-boot.bin") bytes)" || { fail "u-boot.bin missing"; return 1; }
}

build_fw() {   # $1 = SM_TEXT_START, $2 = tag
  sec "3. Upstream firmware target (sm + opensbi), SM_TEXT_START=$1"
  # Serial top-level make on purpose: firmware.mk has no sm->opensbi dependency,
  # so -j at top level could race. Sub-make for OpenSBI is small.
  runlog "fw_$2" "cd '$WORK' && CARGO_NET_OFFLINE=true make -f '$PLAT/firmware.mk' build_path='$BUILD' platform_path='$PLAT' profile=release \
      SM_TEXT_START=$1 FW_TEXT_START=$FW_TEXT_START PMP_COUNT=$PMP_COUNT firmware"
}

verify_fw() {  # $1 = expected SM_TEXT_START ; sets ACTUAL_SM
  sec "4. Verify firmware image layout (expected SM_TEXT_START=$1)"
  [ -f "$FW_ELF" ] || { fail "fw_payload.elf missing"; return 1; }
  run "ls -l '$BUILD'/*.bin"
  run "riscv64-unknown-linux-gnu-readelf -SW '$FW_ELF' | grep -E '^\s+\[|Name'"
  local smi pay fwend smsize smend
  smi=$(sym sm_init); pay=$(sym payload_bin); fwend=$(sym _fw_end)
  smsize=$(stat -c %s "$BUILD/sm.bin")
  ACTUAL_SM="$smi"
  echo "sm_init=$smi  payload_bin=$pay  _fw_end=$fwend  sm.bin=$smsize bytes"
  [ -n "$smi" ] || { fail "symbol sm_init not found (qemu.patch not effective?)"; return 1; }
  if [ "$((smi))" -eq "$(( $1 ))" ]; then ok "sm_init ($smi) == SM_TEXT_START"; else warn "sm_init ($smi) != SM_TEXT_START ($1)"; return 2; fi
  # embedded SM bytes identical to sm.bin
  riscv64-unknown-linux-gnu-objcopy -O binary --only-section=.sm "$FW_ELF" "$ART/.sm_extracted.bin"
  if cmp -n "$smsize" "$ART/.sm_extracted.bin" "$BUILD/sm.bin" >/dev/null; then ok "embedded .sm section == sm.bin"; else fail "embedded .sm differs from sm.bin"; fi
  rm -f "$ART/.sm_extracted.bin"
  smend=$(( smi + smsize ))
  echo "SM range: $(hex $smi) - $(hex $smend)"
  if [ -n "$pay" ] && [ "$smend" -le "$((pay))" ]; then ok "SM ends before U-Boot payload ($(hex $smend) <= $pay)"; else fail "SM overlaps payload"; fi
  run "riscv64-unknown-linux-gnu-objdump -d --start-address=$smi --stop-address=$(( smi + 8 )) '$FW_ELF' | tail -n +7"
  return 0
}

smoke_test() {
  sec "5. QEMU smoke test (firmware only, 30 s, no disk/network)"
  local q="$LOGDIR/${GATE}_build_fw_${TS}_qemu_smoke.log"
  echo "serial console -> logs/$(basename "$q")"
  timeout 30 qemu-system-riscv64 -machine virt -nographic -m 4096M -smp 4 -nic none \
    -bios "$BUILD/fw_payload.bin" </dev/null 2>&1 | tr -d '\r' | sanitize > "$q"
  echo "--- head ---"; head -n 60 "$q"; echo "--- tail ---"; tail -n 25 "$q"
  grep -q 'OpenSBI v'            "$q" && ok "smoke: OpenSBI banner"            || fail "smoke: no OpenSBI banner"
  grep -q 'U-Boot 2024.10'       "$q" && ok "smoke: U-Boot 2024.10 started (SM handed off to S-mode)" || fail "smoke: U-Boot did not start"
  grep -qiE 'panic|sbi_trap_error|illegal instruction|store/amo access fault|load access fault' "$q" \
    && warn "smoke: fault/panic keywords present (inspect smoke log)" || ok "smoke: no panic/trap keywords"
}

main() {
  sec "META"
  echo "gate=$GATE timestamp_utc=$TS nproc=$NPROC"
  # --------------------------------------------------------------------------- 0. checkpoint
  sec "0. CHECKPOINT (every 5 gates): MAIN_TASK.md"
  if [ -f "$MAIN_TASK" ]; then cat "$MAIN_TASK"; ok "MAIN_TASK.md re-read at G05"; else fail "MAIN_TASK.md missing"; fi
  echo; echo "Current position: Phase A-1 (Lattice on QEMU) -> firmware build. Next: G06 rootfs, G07 Linux boot."
  echo; echo "--- gate ledger so far ---"; cat "$LEDGER" 2>/dev/null

  # shellcheck disable=SC1091
  source "$PROJ/env.sh" || { fail "env.sh missing"; return; }
  run "qemu-system-riscv64 --version | head -1"

  stage_sources || { finish; return; }
  build_uboot   || { finish; return; }
  build_fw "$SM_TEXT_START" pass1 && ok "firmware build pass1" || { fail "firmware build pass1"; finish; return; }
  USED_SM="$SM_TEXT_START"
  verify_fw "$SM_TEXT_START"; rc=$?
  if [ $rc -eq 2 ]; then
    sec "4b. Re-link SM at the address OpenSBI actually uses ($ACTUAL_SM)"
    echo "OpenSBI's text size (toolchain-dependent) decides where .sm lands; the SM is"
    echo "position-dependent, so it is rebuilt for that address. No source change."
    USED_SM="$ACTUAL_SM"
    build_fw "$USED_SM" pass2 && ok "firmware build pass2 (SM_TEXT_START=$USED_SM)" || { fail "firmware build pass2"; finish; return; }
    verify_fw "$USED_SM" || { fail "layout still inconsistent after pass2"; finish; return; }
  elif [ $rc -ne 0 ]; then finish; return; fi

  # record parameters actually used (publishable, no host info)
  cat > "$PROJ/fw_params.env" <<EOF
# Firmware parameters verified at $GATE ($TS UTC)
SM_TEXT_START=$USED_SM
FW_TEXT_START=$FW_TEXT_START
PMP_COUNT=$PMP_COUNT
OPENSBI_COMMIT=$OPENSBI_COMMIT
UBOOT_COMMIT=$UBOOT_COMMIT
EOF
  run "cat '$PROJ/fw_params.env'"
  cp -f "$BUILD"/fw_payload.bin "$BUILD"/fw_jump.bin "$BUILD"/fw_dynamic.bin "$BUILD/sm.bin" "$FW_ELF" "$ART/" 2>/dev/null
  ( cd "$ART" && sha256sum *.bin *.elf > SHA256SUMS ); run "cat '$ART/SHA256SUMS'"

  smoke_test
  finish
}
finish() {
  sec "SUMMARY"
  printf '%s\n' "${SUMMARY[@]}"
  NF=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[FAIL\]'); NW=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[WARN\]')
  echo; echo "RESULT: FAIL=$NF WARN=$NW"
}

main 2>&1 | sanitize | tee "$LOG"
RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')
echo "| $GATE | Build OpenSBI+SM+U-Boot, smoke test | $TS | ${RES:-ABORTED} | $(basename "$LOG") | MAIN_TASK re-read |" >> "$LEDGER"
echo; echo ">>> Logs written: logs/${GATE}_build_fw_${TS}*.log"
echo ">>> Please upload the main log and the _qemu_smoke.log to the chat."
