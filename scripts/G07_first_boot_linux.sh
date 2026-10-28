#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G07 - First boot of Ubuntu riscv64 on the Lattice firmware
#   OpenSBI(+Lattice SM) -> U-Boot -> GRUB(EFI) -> Linux -> cloud-init
# What    :
#   1. Pre-flight (fw hash == G05 artifact, files, port, no running VM)
#   2. Start QEMU (machine config = upstream Makefile `qemu` target; see lib/vm.sh)
#   3. Follow the serial console until cloud-init prints LATTICE_CLOUD_INIT_DONE
#      (first boot under TCG installs build-essential + kernel headers: slow)
#   4. Inspect the guest over SSH (kernel, harts, SBI, headers, toolchain)
#   5. Clean poweroff; sanitize serial log; summarize milestones
# Prereq  : scripts/lib/vm.sh  (cp vm.sh scripts/lib/vm.sh)
# Usage   : bash scripts/G07_first_boot_linux.sh        (may take 30-90 min;
#           running inside tmux/screen is recommended)
# Writes  : logs/G07_first_boot_<UTC>.log, logs/G07_first_boot_<UTC>_serial.log,
#           work/run/*, work/guest/known_hosts, logs/GATE_LEDGER.md
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
LOGDIR="$PROJ/logs"
GATE="G07"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_first_boot_${TS}.log"
SERIAL="$LOGDIR/${GATE}_first_boot_${TS}_serial.log"
LEDGER="$LOGDIR/GATE_LEDGER.md"
TIMEOUT_SEC="${TIMEOUT_SEC:-7200}"      # 2 h upper bound for first boot + cloud-init
POLL=20

# shellcheck disable=SC1091
source "$PROJ/scripts/lib/vm.sh" || { echo "scripts/lib/vm.sh missing"; exit 1; }
mkdir -p "$LOGDIR"

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
gssh() { printf '\n[guest]$ %s\n' "$*"; vm_ssh "$*" 2>&1; local r=$?; printf '(exit=%s)\n' "$r"; return $r; }
finish() {
  sec "SUMMARY"; printf '%s\n' "${SUMMARY[@]}"
  NF=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[FAIL\]'); NW=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[WARN\]')
  echo; echo "RESULT: FAIL=$NF WARN=$NW"
}

# milestone table: key | regex | description
MS_KEYS=(opensbi uboot linux smp login cidone)
declare -A MS_RE=(
  [opensbi]='OpenSBI v'
  [uboot]='U-Boot 2024\.10'
  [linux]='Linux version [0-9]'
  [smp]='smp: Brought up'
  [login]='login:'
  [cidone]='LATTICE_CLOUD_INIT_DONE'
)
declare -A MS_DESC=(
  [opensbi]="OpenSBI banner (M-mode firmware)"
  [uboot]="U-Boot (S-mode) reached -> SM handed off"
  [linux]="Linux kernel started"
  [smp]="secondary harts brought up (SBI HSM through SM)"
  [login]="getty login prompt"
  [cidone]="cloud-init finished (headers installed)"
)
declare -A MS_T=()
CI_VIA_SSH=""
FAULT_RE='Kernel panic|Oops|Unable to handle kernel|sbi_trap_error|watchdog: BUG|rcu: INFO: rcu_.*stall'

main() {
  sec "META"; echo "gate=$GATE timestamp_utc=$TS timeout=${TIMEOUT_SEC}s"

  # --------------------------------------------------------------------------- 1. pre-flight
  sec "1. Pre-flight"
  local miss=0
  for f in "$VM_FW" "$VM_DISK" "$VM_SEED" "$VM_KEY"; do [ -f "$f" ] && echo "ok      $f" || { echo "MISSING $f"; miss=1; }; done
  [ $miss -eq 0 ] && ok "inputs present" || { fail "inputs missing"; finish; return; }
  local want have
  want=$(awk '$2=="fw_payload.bin"{print $1}' "$PROJ/work/artifacts/fw-release/SHA256SUMS" 2>/dev/null)
  have=$(sha256sum "$VM_FW" | awk '{print $1}')
  echo "fw_payload.bin sha256=$have (G05 artifact: $want)"
  [ -n "$want" ] && [ "$want" = "$have" ] && ok "firmware == G05 verified build" || warn "firmware differs from G05 artifact"
  run "qemu-system-riscv64 --version | head -1"
  echo "QEMU command line:"; vm_cmdline "$SERIAL" | sed 's/^/    /'

  # --------------------------------------------------------------------------- 2. start
  sec "2. Start VM"
  local t0; t0=$(date +%s)
  if vm_start "$SERIAL"; then ok "QEMU started (pid $(cat "$VM_RUN/qemu.pid"))"; else fail "QEMU start"; finish; return; fi

  # --------------------------------------------------------------------------- 3. follow console
  sec "3. Follow serial console (poll ${POLL}s, max ${TIMEOUT_SEC}s)"
  local now el k last_sz=0 sz died=0
  while :; do
    sleep "$POLL"; now=$(date +%s); el=$((now - t0))
    for k in "${MS_KEYS[@]}"; do
      if [ -z "${MS_T[$k]:-}" ] && grep -aqE "${MS_RE[$k]}" "$SERIAL" 2>/dev/null; then
        MS_T[$k]=$el; printf '  [+%5ds] milestone: %s\n' "$el" "${MS_DESC[$k]}"
      fi
    done
    if grep -aqE "$FAULT_RE" "$SERIAL" 2>/dev/null; then
      echo "  [+${el}s] FAULT pattern detected on console"; break; fi
    # cloud-init's final message may go to tty1 instead of ttyS0 depending on
    # the image's console= order, so also ask the guest directly once it is up.
    if [ -z "${MS_T[cidone]:-}" ] && [ -n "${MS_T[uboot]:-}" ] && [ "$el" -ge 300 ] && [ $(( el % 60 )) -lt "$POLL" ]; then
      local cis; cis=$(timeout 20 bash -c 'source "$0"; vm_ssh "cloud-init status 2>/dev/null"' "$PROJ/scripts/lib/vm.sh" 2>/dev/null)
      case "$cis" in *"status: done"*|*"status: error"*|*"status: degraded"*)
        MS_T[cidone]=$el; CI_VIA_SSH="$cis"; printf '  [+%5ds] milestone: %s (via ssh: %s)\n' "$el" "${MS_DESC[cidone]}" "$(echo $cis)";;
      esac
    fi
    [ -n "${MS_T[cidone]:-}" ] && break
    if ! vm_running; then echo "  [+${el}s] QEMU exited unexpectedly"; died=1; break; fi
    if [ "$el" -ge "$TIMEOUT_SEC" ]; then echo "  [+${el}s] timeout"; break; fi
    sz=$(stat -c %s "$SERIAL" 2>/dev/null || echo 0)
    if [ $(( el % 300 )) -lt "$POLL" ]; then
      printf '  [+%5ds] console %d bytes (+%d), last line: %s\n' "$el" "$sz" $((sz - last_sz)) \
        "$(tail -c 2000 "$SERIAL" | tr -d '\r' | grep -av '^\s*$' | tail -1 | cut -c1-100)"; last_sz=$sz
    fi
  done

  sec "3b. Milestones"
  # required: opensbi, uboot, cidone ; console-only milestones (kernel console
  # may not be on ttyS0) are WARN when missing and re-checked via dmesg below
  for k in "${MS_KEYS[@]}"; do
    if [ -n "${MS_T[$k]:-}" ]; then printf '  %-8s +%5ss  %s\n' "$k" "${MS_T[$k]}" "${MS_DESC[$k]}"; ok "boot: ${MS_DESC[$k]} (+${MS_T[$k]}s)"
    else printf '  %-8s  ----   %s\n' "$k" "${MS_DESC[$k]}"
      case "$k" in opensbi|uboot|cidone) fail "boot: not reached - ${MS_DESC[$k]}";; *) warn "not seen on serial console - ${MS_DESC[$k]}";; esac
    fi
  done
  [ -n "${CI_VIA_SSH:-}" ] && echo "cloud-init completion detected via ssh: $(echo $CI_VIA_SSH)"
  case "${CI_VIA_SSH:-}" in *error*|*degraded*) warn "cloud-init finished with errors/degraded (see status --long below)";; esac
  local nh; nh=$(grep -acE 'hart [0-9]+ started' "$SERIAL" 2>/dev/null)
  echo "SM/OpenSBI 'hart N started' messages: $nh (expected $VM_SMP: boot hart + secondaries)"
  [ "$nh" -ge "$VM_SMP" ] && ok "all $VM_SMP harts passed sbi_hsm start through the patched path" || warn "only $nh hart-start messages"
  if grep -aqE "$FAULT_RE" "$SERIAL"; then fail "fault/panic pattern on console"; run "grep -anE '$FAULT_RE' '$SERIAL' | head -20"; else ok "no panic/oops/trap-error on console"; fi

  # --------------------------------------------------------------------------- 4. guest inspection
  if [ $died -eq 0 ] && vm_running; then
    sec "4. Guest inspection over SSH"
    if vm_wait_ssh 600; then
      ok "SSH login with project key"
      gssh 'uname -a; grep -E "^(PRETTY_NAME|VERSION_ID)" /etc/os-release'
      gssh 'nproc; free -m | head -2; df -h / | tail -1'
      gssh 'grep -E "^(isa|mmu|hart)" /proc/cpuinfo | sort | uniq -c'
      gssh 'cat /proc/cmdline'
      gssh 'cloud-init status --long 2>/dev/null | head -8'
      if vm_ssh 'test -f /var/lib/lattice-headers-ok && test -d /lib/modules/$(uname -r)/build'; then
        ok "kernel headers for running kernel installed (/lib/modules/\$(uname -r)/build)"
      else fail "kernel headers missing in guest"; fi
      gssh 'gcc --version | head -1; make --version | head -1'
      gssh 'sudo dmesg | grep -iE "sbi|smp:|riscv: |pmp|Machine model|Memory:" | head -40'
      if vm_ssh 'sudo dmesg | grep -q "smp: Brought up.* '"$VM_SMP"' CPUs"'; then ok "kernel brought up all $VM_SMP CPUs (dmesg)"; else warn "dmesg does not show $VM_SMP CPUs brought up"; fi
      gssh 'sudo dmesg --level=err,crit,alert,emerg | tail -20'
      gssh 'systemctl --failed --no-legend | head'
    else fail "SSH not reachable within 600 s after console milestones"; fi

    sec "5. Clean shutdown"
    vm_stop
    vm_running && fail "VM still running after vm_stop" || ok "VM stopped"
  else
    fail "VM not running at inspection stage"
  fi
  echo "total_elapsed_sec=$(( $(date +%s) - t0 ))"

  # --------------------------------------------------------------------------- 6. serial excerpt
  sec "6. Serial console excerpt (full: logs/$(basename "$SERIAL"))"
  tr -d '\r' < "$SERIAL" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | grep -aE \
    'OpenSBI v|Domain0 Region|Boot HART|hart [0-9]+ started|U-Boot 20|Booting|EFI stub|Linux version|Machine model|SBI specification|SBI implementation|riscv: ISA|smp:|Memory:|Run /init|systemd\[1\]: (Detected|Reached target Multi)|login:|LATTICE_CLOUD_INIT_DONE|panic|Oops' | head -80
  finish
}

main 2>&1 | sanitize | tee "$LOG"
# sanitize the raw serial log in place (guest output can echo host-provided data)
if [ -f "$SERIAL" ]; then
  tmp="$(mktemp)"; tr -d '\r' < "$SERIAL" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | sanitize > "$tmp" && cat "$tmp" > "$SERIAL"; rm -f "$tmp"
fi
RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')
echo "| $GATE | First Linux boot on Lattice fw (cloud-init) | $TS | ${RES:-ABORTED} | $(basename "$LOG") | - |" >> "$LEDGER"
echo; echo ">>> Logs: logs/$(basename "$LOG") and logs/$(basename "$SERIAL")"
echo ">>> Please upload both files to the chat."
