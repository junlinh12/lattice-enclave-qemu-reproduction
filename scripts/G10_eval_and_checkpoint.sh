#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G10 (v1) - Functional matrix + key evaluation   [CHECKPOINT]
#   0. CHECKPOINT: re-read ~/projects/MAIN_TASK.md (R3)
#   1. Host: build payloads (tests/enclave/{empty,bench}.c, tests/tools/memfill.c)
#   2. Guest: boot, stage, teectl, LSE
#   3. Functional matrix: LSE / LUE (hello, empty, bench) / LDE (static check only:
#      public SM create_enclave() handles User(1)+Service(3); Driver(2) -> panic)
#   4. Latency: empty payload end-to-end x10 (native vs LUE), bench x3
#      (getpid = handled inside enclave runtime, write(/dev/null) = proxied
#       through SM + host client, compute loop)
#   5. Concurrency: test_launcher with 2 / 4 / 8 parallel LUEs
#   6. Memory-reuse experiment (G09 shutdown hang hypothesis):
#      A) LSE alive  -> fill 85% of free RAM (control; also re-uses LUE pages)
#      B) kill LSE holder -> fill again (if the SM still PMP-protects the freed
#         LSE pages, Linux stalls here)
#   7. Graceful shutdown attempt + serial excerpt
# Note    : QEMU TCG timings are NOT hardware numbers; only ratios are meaningful.
# Usage   : bash scripts/G10_eval_and_checkpoint.sh      (~15-30 min, tmux recommended)
# Writes  : logs/G10_eval_<UTC>*.log, logs/G10_eval_<UTC>_results.csv,
#           tests/enclave/{empty,bench}.c, tests/tools/memfill.c, logs/GATE_LEDGER.md
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
WORK="$PROJ/work/Lattice"
STAGE="$PROJ/work/stage/lattice"
LOGDIR="$PROJ/logs"
GATE="G10"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_eval_${TS}.log"
SERIAL="$LOGDIR/${GATE}_eval_${TS}_serial.log"
CSV="$LOGDIR/${GATE}_eval_${TS}_results.csv"
LEDGER="$LOGDIR/GATE_LEDGER.md"
MAIN_TASK="$HOME/projects/MAIN_TASK.md"
CC=riscv64-unknown-linux-gnu-gcc

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
info() { SUMMARY+=("[INFO] $*"); }
sec()  { printf '\n==================== %s ====================\n' "$*"; }
run()  { printf '\n$ %s\n' "$*"; bash -o pipefail -c "$*" 2>&1; local r=$?; printf '(exit=%s)\n' "$r"; return $r; }
gssh() { printf '\n[guest]$ %s\n' "$*"; vm_ssh "$*" 2>&1; local r=$?; printf '(exit=%s)\n' "$r"; return $r; }
finish() {
  sec "SUMMARY"; printf '%s\n' "${SUMMARY[@]}"
  NF=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[FAIL\]'); NW=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[WARN\]')
  echo; echo "RESULT: FAIL=$NF WARN=$NW"
}
alive() { vm_running && vm_ssh true 2>/dev/null; }
serial_mark() { stat -c %s "$SERIAL" 2>/dev/null || echo 0; }
serial_since() { sleep 2; local s1; s1=$(serial_mark)
  [ "$s1" -gt "$1" ] && { echo "--- serial since mark ---"; tail -c +"$(( $1 + 1 ))" "$SERIAL" | head -c 6000 | tr -d '\r' | sanitize | tail -n 25; }; }
stats() {  # stats <values...> -> "n= mean= median= min= max="
  printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1; s+=$1} END{ if(NR==0){print "n=0"; exit}
    m=(NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2; printf "n=%d mean=%.1f median=%.1f min=%s max=%s", NR, s/NR, m, a[1], a[NR]}'; }

write_sources() {
  mkdir -p "$PROJ/tests/enclave" "$PROJ/tests/tools"
  [ -f "$PROJ/tests/enclave/empty.c" ] || cat > "$PROJ/tests/enclave/empty.c" <<'EOF'
/* Empty enclave payload: isolates enclave create/launch/teardown cost. */
int main(void) { return 0; }
EOF
  [ -f "$PROJ/tests/enclave/bench.c" ] || cat > "$PROJ/tests/enclave/bench.c" <<'EOF'
/* Micro-benchmark payload for the Lattice LUE (reproduction harness).
 *  getpid          : served inside the enclave runtime (no world switch to Linux)
 *  write(/dev/null): proxied enclave -> SM -> host client -> Linux -> back
 *  compute         : pure user-mode loop (should be ~native)               */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static long long now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}
int main(void) {
    const int NG = 10000, NW = 1000; const long NC = 50000000L;
    long long t0 = now();
    for (int i = 0; i < NG; i++) syscall(SYS_getpid);
    long long t1 = now();
    int fd = open("/dev/null", O_WRONLY); char c = 'x'; int werr = 0;
    long long t2 = now();
    for (int i = 0; i < NW; i++) if (write(fd, &c, 1) != 1) { werr = 1; break; }
    long long t3 = now();
    if (fd >= 0) close(fd);
    volatile unsigned long s = 0;
    long long t4 = now();
    for (long i = 0; i < NC; i++) s += i;
    long long t5 = now();
    printf("BENCH getpid n=%d total_ns=%lld per_ns=%lld\n", NG, t1 - t0, (t1 - t0) / NG);
    printf("BENCH write_devnull n=%d total_ns=%lld per_ns=%lld fd=%d err=%d\n", NW, t3 - t2, (t3 - t2) / NW, fd, werr);
    printf("BENCH compute n=%ld total_ns=%lld sum=%lu\n", NC, t5 - t4, (unsigned long)s);
    fflush(stdout);
    return 0;
}
EOF
  [ -f "$PROJ/tests/tools/memfill.c" ] || cat > "$PROJ/tests/tools/memfill.c" <<'EOF'
/* memfill <MB>: allocate and write <MB> MiB (64 MiB chunks) to force page reuse. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    size_t mb = argc > 1 ? strtoul(argv[1], 0, 10) : 256, done = 0, chunk = 64UL << 20;
    while (done < mb) {
        char *p = malloc(chunk);
        if (!p) { printf("MEMFILL malloc failed at %zu MB\n", done); return 1; }
        memset(p, 0xA5, chunk); done += 64;
    }
    printf("MEMFILL_OK %zu MB\n", done); fflush(stdout); return 0;
}
EOF
}

main() {
  sec "META"; echo "gate=$GATE (v1) timestamp_utc=$TS"
  echo "metric,mode,payload,run,value,unit" > "$CSV"

  # --------------------------------------------------------------------------- 0. checkpoint
  sec "0. CHECKPOINT (every 5 gates): MAIN_TASK.md"
  if [ -f "$MAIN_TASK" ]; then cat "$MAIN_TASK"; ok "MAIN_TASK.md re-read at G10"; else fail "MAIN_TASK.md missing"; fi
  echo; echo "Position: Phase A-1 (Lattice on QEMU). G09 v2 = first successful LSE+LUE. Next: G11 sanitize, G12 publish, then Phase A-2 (IBM ACE)."
  echo; echo "--- gate ledger ---"; cat "$LEDGER"

  # --------------------------------------------------------------------------- 1. host build
  sec "1. Host: build payloads"
  # shellcheck disable=SC1091
  source "$PROJ/env.sh" || { fail "env.sh missing"; finish; return; }
  write_sources
  run "$CC -static -O2 -o '$STAGE/empty'   '$PROJ/tests/enclave/empty.c'" && ok "empty built"   || fail "empty build"
  run "$CC -static -O2 -o '$STAGE/bench'   '$PROJ/tests/enclave/bench.c'" && ok "bench built"   || fail "bench build"
  run "$CC -static -O2 -o '$STAGE/memfill' '$PROJ/tests/tools/memfill.c'" && ok "memfill built" || fail "memfill build"
  ( cd "$STAGE" && find . -type f ! -name 'SHA256SUMS*' ! -name '*.out' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS )
  run "cat '$STAGE/SHA256SUMS'"

  sec "1b. LDE support in public SM source (static check, not executed)"
  run "grep -n 'USER_ENC\\|SER_ENC\\|unknown enclave type' '$WORK/crates/sm/src/sm.rs'"
  run "grep -n 'in(\"a1\")' '$WORK/crates/channel/src/enclave.rs'"
  if grep -q 'DRV_ENC\|Driver as usize' "$WORK/crates/sm/src/sm.rs"; then info "SM source references a Driver enclave path (inspect)"
  else warn "LDE not implemented in public SM: create_enclave() accepts User(1)/Service(3) only; client --lde sends 2 -> SM panic. Not executed."; fi

  # --------------------------------------------------------------------------- 2. guest setup
  sec "2. Boot, stage, teectl, LSE"
  local t0; t0=$(date +%s)
  vm_start "$SERIAL" && ok "QEMU started" || { fail "QEMU start"; finish; return; }
  vm_wait_ssh 900 && ok "SSH up after $(( $(date +%s)-t0 )) s" || { fail "SSH not reachable"; vm_stop; finish; return; }
  tar -C "$STAGE" -cf - . | vm_ssh 'rm -rf ~/lattice && mkdir -p ~/lattice && tar -C ~/lattice -xf -'
  gssh 'cd ~/lattice && sha256sum -c --quiet SHA256SUMS && echo checksums-OK' && ok "stage verified in guest" || fail "stage checksum mismatch"
  gssh 'cd ~/lattice/tee_mod && make build >/dev/null 2>&1; sudo insmod teectl.ko && ls -l /dev/teectl' && ok "teectl loaded" || { fail "teectl"; vm_stop; finish; return; }
  gssh 'cd ~/lattice && sudo sh -c "nohup ./client --lse -c config.toml > lse.out 2>&1 < /dev/null &"; for i in $(seq 1 60); do grep -q "lse created" lse.out 2>/dev/null && break; sleep 2; done; tail -3 lse.out'
  vm_ssh 'grep -q "lse created" ~/lattice/lse.out && pgrep -f "[c]lient --lse" >/dev/null' && ok "F1 LSE created" || { fail "F1 LSE"; vm_stop; finish; return; }

  # --------------------------------------------------------------------------- 3. functional
  sec "3. Functional matrix (LUE payloads)"
  local p out
  for p in hello empty bench; do
    out=$(vm_ssh "cd ~/lattice && sudo timeout 300 ./client -c config.toml ./$p 2>&1; echo __RC=\$?" 2>&1)
    echo "--- LUE $p ---"; echo "$out" | grep -vE '^(alloc size|fd:|command:|mmap fd|size:|mmap addr)' | head -20
    if echo "$out" | grep -q 'enclave finished' && echo "$out" | grep -q '__RC=0'; then ok "F2 LUE $p runs to completion"; else fail "F2 LUE $p"; fi
    alive || { fail "guest lost after LUE $p"; finish; return; }
  done

  # --------------------------------------------------------------------------- 4. latency
  sec "4. Latency (inside guest, one sudo per batch; TCG)"
  local res
  res=$(vm_ssh 'cd ~/lattice && sudo bash -c '"'"'
    for i in $(seq 1 10); do s=$(date +%s%N); ./empty; rc=$?; e=$(date +%s%N); echo "RUN native empty $i $(( (e-s)/1000 )) $rc"; done
    for i in $(seq 1 10); do s=$(date +%s%N); timeout 300 ./client -c config.toml ./empty >/tmp/o 2>&1; rc=$?; e=$(date +%s%N)
      f=$(grep -c "enclave finished" /tmp/o); echo "RUN lue empty $i $(( (e-s)/1000 )) $rc $f"; done
    for i in 1 2 3; do ./bench | sed "s/^/native $i /"; done
    for i in 1 2 3; do timeout 300 ./client -c config.toml ./bench 2>&1 | grep "^BENCH" | sed "s/^/lue $i /"; done
  '"'"'' 2>&1)
  echo "$res"
  alive || { fail "guest lost during latency runs"; finish; return; }
  local m
  for m in native lue; do
    local vals; vals=$(echo "$res" | awk -v m="$m" '$1=="RUN" && $2==m && $3=="empty" {print $5/1000}')
    echo "$res" | awk -v m="$m" '$1=="RUN" && $2==m && $3=="empty" {printf "e2e_latency,%s,empty,%s,%.1f,ms\n", m, $4, $5/1000}' >> "$CSV"
    echo "e2e empty [$m] ms: $(stats $vals)"
  done
  local nok; nok=$(echo "$res" | awk '$1=="RUN" && $2=="lue" && $6==0 && $7==1' | wc -l)
  [ "$nok" -eq 10 ] && ok "L1 10/10 LUE(empty) runs completed" || fail "L1 only $nok/10 LUE(empty) runs completed"
  local b
  for b in getpid write_devnull compute; do
    for m in native lue; do
      local key=per_ns; [ "$b" = compute ] && key=total_ns
      vals=$(echo "$res" | awk -v m="$m" -v b="$b" -v k="$key" '$1==m && $3=="BENCH" && $4==b { for(i=5;i<=NF;i++){split($i,kv,"="); if(kv[1]==k) print kv[2]} }')
      echo "$res" | awk -v m="$m" -v b="$b" -v k="$key" '$1==m && $3=="BENCH" && $4==b { for(i=5;i<=NF;i++){split($i,kv,"="); if(kv[1]==k) printf "%s,%s,bench,%s,%s,%s\n", b, m, $2, kv[2], (k=="per_ns"?"ns/op":"ns")} }' >> "$CSV"
      echo "bench $b [$m] $key: $(stats $vals)"
    done
  done
  echo "$res" | grep -q '^lue .*BENCH write_devnull.*err=0' && ok "L2 proxied write() works inside enclave" || warn "L2 proxied write() errors in enclave (see bench output)"

  # --------------------------------------------------------------------------- 5. concurrency
  sec "5. Concurrency (test_launcher, parallel LUEs)"
  local n s0 cout fin
  for n in 2 4 8; do
    s0=$(serial_mark)
    cout=$(vm_ssh "cd ~/lattice && sudo timeout 600 ./test_launcher './client -c config.toml ./hello' $n 2>&1" 2>&1); local crc=$?
    fin=$(echo "$cout" | grep -c 'enclave finished'); local sums; sums=$(echo "$cout" | grep -c 'LATTICE_ENCLAVE_SUM=499999500000')
    echo "N=$n ssh_rc=$crc finished=$fin correct_sums=$sums"
    echo "concurrency_finished,lue,hello,N$n,$fin,count" >> "$CSV"
    if [ "$crc" -eq 255 ] || ! alive; then fail "C$n guest lost with $n parallel LUEs"; serial_since "$s0"; finish; return; fi
    [ "$fin" -eq "$n" ] && [ "$sums" -eq "$n" ] && ok "C$n $n/$n parallel LUEs correct" || { fail "C$n only $fin/$n finished ($sums correct)"; echo "$cout" | tail -30; serial_since "$s0"; }
  done
  gssh 'sudo dmesg | grep -iE "Oops|BUG:|lockup|stall" | tail -5; free -m | head -2'

  # --------------------------------------------------------------------------- 6. memory reuse
  sec "6. Memory-reuse experiment (G09 shutdown-hang hypothesis)"
  local mb
  mb=$(vm_ssh "sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'; awk '/MemAvailable/ {printf \"%d\", \$2/1024*0.85}' /proc/meminfo" 2>/dev/null)
  echo "fill size = 85% of MemAvailable = ${mb} MB"
  s0=$(serial_mark)
  gssh "cd ~/lattice && timeout 300 ./memfill $mb; echo __RC=\$?"
  if alive; then ok "M-A control: fill ${mb} MB with LSE alive (re-uses cleaned LUE pages) OK"
  else fail "M-A control fill hung the guest"; serial_since "$s0"; finish; return; fi
  gssh 'sudo pkill -f "[c]lient --lse"; sleep 2; pgrep -af "[c]lient --lse" || echo "LSE holder gone"; sudo dmesg | grep teectl | tail -2'
  s0=$(serial_mark)
  printf '\n[guest]$ timeout 300 ./memfill %s   (after LSE holder exit)\n' "$mb"
  out=$(vm_ssh "cd ~/lattice && timeout 300 ./memfill $mb; echo __RC=\$?" 2>&1); local mrc=$?
  echo "$out"; echo "ssh_rc=$mrc"
  serial_since "$s0"
  if [ "$mrc" -eq 255 ] || ! alive; then
    info "M-B HYPOTHESIS SUPPORTED: after the LSE holder exits, reusing its freed pages stalls Linux (SM keeps them PMP-protected; no LSE destroy path)"
  elif echo "$out" | grep -q 'MEMFILL_OK'; then
    info "M-B HYPOTHESIS NOT SUPPORTED: memory fill after LSE exit succeeded"
  else info "M-B inconclusive (see output)"; fi

  # --------------------------------------------------------------------------- 7. shutdown
  sec "7. Graceful shutdown attempt"
  local so; so=$(vm_stop 2>&1); echo "$so"
  echo "$so" | grep -q 'guest powered off' && info "graceful poweroff succeeded" || info "graceful poweroff did NOT complete (forced quit)"
  vm_running && fail "VM still running" || ok "VM stopped"

  sec "8. Serial: SM lines"
  tr -d '\r' < "$SERIAL" | grep -anE 'panicked|\[INFO\]|\[WARN|\[ERROR|Oops|lockup|stall' | head -80
  sec "9. Results CSV (logs/$(basename "$CSV"))"; cat "$CSV"
  finish
}

main 2>&1 | sanitize | tee "$LOG"
if [ -f "$SERIAL" ]; then
  tmp="$(mktemp)"; tr -d '\r' < "$SERIAL" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | sanitize > "$tmp" && cat "$tmp" > "$SERIAL"; rm -f "$tmp"
fi
RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')
echo "| $GATE | Functional matrix + evaluation (latency, concurrency, mem-reuse) | $TS | ${RES:-ABORTED} | $(basename "$LOG") | MAIN_TASK re-read |" >> "$LEDGER"
echo; echo ">>> Logs: logs/${GATE}_eval_${TS}*.log and _results.csv"
echo ">>> Please upload the main log, _serial.log and _results.csv."
