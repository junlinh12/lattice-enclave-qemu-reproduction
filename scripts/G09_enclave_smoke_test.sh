#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G09 (v2) - First Lattice enclave run: LSE first, then LUE
# Finding from G09 v1 (20261028T054214Z):
#   SM panicked at crates/sm/src/sm.rs:211 `self.enc_mgr.get_lse(0).unwrap()`.
#   create_lue() maps the runtime + trampoline of an existing Linux *Service*
#   Enclave (LSE) into every new LUE, so an LSE must be registered first
#   (`client --lse`, which keeps running to hold its memory). Upstream has no
#   README describing this order; it is derived from the SM source.
# Flow (v2):
#   1. boot, copy + verify stage, insmod teectl
#   2. LSE : sudo client --lse -c config.toml   (background, never exits)
#   3. LUE : sudo client -c config.toml ./hello  x3  (sequential re-use check)
#   4. guest health after runs, shutdown, serial excerpt
# Note    : CLI declares `-l` for both --lde and --lse -> long options only.
#           hello-pie dropped: Ubuntu's cross glibc has no rcrt1.o (static-pie).
# Usage   : bash scripts/G09_enclave_smoke_test.sh
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
STAGE="$PROJ/work/stage/lattice"
LOGDIR="$PROJ/logs"
GATE="G09"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_enclave_smoke_${TS}.log"
SERIAL="$LOGDIR/${GATE}_enclave_smoke_${TS}_serial.log"
LEDGER="$LOGDIR/GATE_LEDGER.md"
RUN_TIMEOUT=300
EXPECT_SUM="LATTICE_ENCLAVE_SUM=499999500000"

# shellcheck disable=SC1091
source "$PROJ/scripts/lib/vm.sh" || { echo "scripts/lib/vm.sh missing"; exit 1; }
mkdir -p "$LOGDIR"

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
sec()  { printf '\n==================== %s ====================\n' "$*"; }
run()  { printf '\n$ %s\n' "$*"; bash -o pipefail -c "$*" 2>&1; local r=$?; printf '(exit=%s)\n' "$r"; return $r; }
gssh() { printf '\n[guest]$ %s\n' "$*"; vm_ssh "$*" 2>&1; local r=$?; printf '(exit=%s)\n' "$r"; return $r; }
finish() {
  sec "SUMMARY"; printf '%s\n' "${SUMMARY[@]}"
  NF=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[FAIL\]'); NW=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[WARN\]')
  echo; echo "RESULT: FAIL=$NF WARN=$NW"
}
serial_since() {  # serial_since <byte offset> : print sanitized console output after offset
  local s1; sleep 2; s1=$(stat -c %s "$SERIAL" 2>/dev/null || echo 0)
  if [ "$s1" -gt "$1" ]; then
    echo "--- serial console since step start (SM/runtime/kernel) ---"
    tail -c +"$(( $1 + 1 ))" "$SERIAL" | head -c 8000 | tr -d '\r' | sanitize | tail -n 40
  fi
}

# enclave_run <tag> <binary>
enclave_run() {
  local tag="$1" bin="$2" out="$LOGDIR/${GATE}_enclave_smoke_${TS}_${1}.log"
  local s0 t0 t1 rc crc
  s0=$(stat -c %s "$SERIAL" 2>/dev/null || echo 0)
  printf '\n[guest]$ sudo timeout %s ./client -c config.toml ./%s   (output -> logs/%s)\n' "$RUN_TIMEOUT" "$bin" "$(basename "$out")"
  t0=$(date +%s%N)
  vm_ssh "cd ~/lattice && sudo timeout $RUN_TIMEOUT ./client -c config.toml ./$bin; echo \"__CLIENT_RC=\$?\"" 2>&1 | sanitize > "$out"
  rc=${PIPESTATUS[0]}; t1=$(date +%s%N)
  sed -n '1,60p' "$out"
  echo "ssh_rc=$rc  wall_ms=$(( (t1 - t0) / 1000000 ))"
  serial_since "$s0"
  crc=$(grep -o '__CLIENT_RC=[0-9]*' "$out" | tail -1 | cut -d= -f2)
  if [ "$rc" -eq 255 ]; then fail "$tag: SSH connection lost (guest hang/crash?)"; return 2; fi
  grep -q 'lue created'           "$out" && ok "$tag: LUE created (SM create_lue)"        || fail "$tag: LUE not created"
  grep -q 'LATTICE_ENCLAVE_HELLO' "$out" && ok "$tag: enclave write() proxied to host"   || fail "$tag: no enclave output"
  grep -q "$EXPECT_SUM"           "$out" && ok "$tag: enclave computation correct"         || fail "$tag: wrong/missing result"
  grep -q 'enclave finished'      "$out" && ok "$tag: enclave exited cleanly"              || fail "$tag: no clean exit"
  [ "${crc:-x}" = "0" ] && ok "$tag: client exit code 0" || fail "$tag: client exit code ${crc:-?} (124 = timeout)"
  return 0
}

main() {
  sec "META"; echo "gate=$GATE (v2: LSE before LUE) timestamp_utc=$TS run_timeout=${RUN_TIMEOUT}s"

  # --------------------------------------------------------------------------- 1. boot + stage
  sec "1. Boot guest, copy & verify stage, load teectl"
  rm -f "$STAGE/hello-pie"
  ( cd "$STAGE" && find . -type f ! -name 'SHA256SUMS*' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS )
  run "cat '$STAGE/SHA256SUMS'"
  local t0; t0=$(date +%s)
  vm_start "$SERIAL" && ok "QEMU started" || { fail "QEMU start"; finish; return; }
  vm_wait_ssh 900 && ok "SSH up after $(( $(date +%s)-t0 )) s" || { fail "SSH not reachable"; vm_stop; finish; return; }
  tar -C "$STAGE" -cf - . | vm_ssh 'rm -rf ~/lattice && mkdir -p ~/lattice && tar -C ~/lattice -xf -' && ok "stage copied" || fail "copy stage"
  gssh 'cd ~/lattice && sha256sum -c --quiet SHA256SUMS && echo checksums-OK' && ok "stage checksums verified in guest" || fail "stage checksum mismatch"
  gssh 'cd ~/lattice/tee_mod && make build >/dev/null 2>&1; sudo insmod teectl.ko && ls -l /dev/teectl' \
    && ok "teectl.ko built + loaded" || { fail "teectl not loaded"; vm_stop; finish; return; }

  sec "2. Native baseline (outside enclave)"
  gssh 'cd ~/lattice && s=$(date +%s%N); ./hello; e=$(date +%s%N); echo "native hello: $(( (e-s)/1000000 )) ms"'

  # --------------------------------------------------------------------------- 3. LSE
  sec "3. Register Linux Service Enclave (client --lse, background)"
  local s0; s0=$(stat -c %s "$SERIAL" 2>/dev/null || echo 0)
  gssh 'cd ~/lattice && sudo sh -c "nohup ./client --lse -c config.toml > lse.out 2>&1 < /dev/null &"; for i in $(seq 1 60); do grep -q "lse created" lse.out 2>/dev/null && break; sleep 2; done; cat lse.out; pgrep -af "[c]lient --lse"'
  local lrc=$?
  serial_since "$s0"
  if [ $lrc -eq 255 ]; then fail "LSE: SSH lost during create_lse (guest hang?)"; vm_stop; finish; return; fi
  if vm_ssh 'grep -q "lse created" ~/lattice/lse.out && pgrep -f "[c]lient --lse" >/dev/null'; then
    ok "LSE created and holder process alive"
  else fail "LSE not created"; vm_stop; finish; return; fi

  # --------------------------------------------------------------------------- 4. LUE runs
  sec "4. Linux User Enclave runs (x3, sequential)"
  local i
  for i in 1 2 3; do
    enclave_run "T1_hello_run$i" hello || break
    vm_running || { fail "VM died during run $i"; break; }
  done

  # --------------------------------------------------------------------------- 5. health
  if vm_running && vm_ssh true 2>/dev/null; then
    sec "5. Guest health after runs"
    gssh 'pgrep -af "[c]lient --lse"; cat ~/lattice/lse.out | tail -5'
    gssh 'sudo dmesg | grep -iE "teectl|Oops|BUG|panic|lockup|stall" | tail -30'
    gssh 'sudo dmesg --level=err,crit,alert,emerg | tail -10'
    gssh 'free -m | head -2; uptime'
    if vm_ssh 'sudo dmesg | grep -qiE "Oops|BUG:|lockup|rcu.*stall"'; then warn "kernel reported Oops/lockup/stall"; else ok "no Oops/lockup/stall in guest after runs"; fi
    sec "6. Shutdown"; vm_stop
  else
    sec "6. Forced stop (guest unresponsive)"; vm_stop
  fi
  vm_running && fail "VM still running" || ok "VM stopped"

  sec "7. Serial console: SM / fault lines"
  tr -d '\r' < "$SERIAL" | grep -anE 'panicked|\bSM\b|\[sm|sm::|[Ee]nclave|LUE|LSE|eid|owned pma|md5|Oops|lockup|stall' | grep -v 'systemd\|apparmor' | head -80
  finish
}

main 2>&1 | sanitize | tee "$LOG"
if [ -f "$SERIAL" ]; then
  tmp="$(mktemp)"; tr -d '\r' < "$SERIAL" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | sanitize > "$tmp" && cat "$tmp" > "$SERIAL"; rm -f "$tmp"
fi
RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')
echo "| $GATE | Enclave run v2 (LSE + LUE hello x3) | $TS | ${RES:-ABORTED} | $(basename "$LOG") | - |" >> "$LEDGER"
echo; echo ">>> Logs: logs/${GATE}_enclave_smoke_${TS}*.log"
echo ">>> Please upload the main log and the _serial.log."
