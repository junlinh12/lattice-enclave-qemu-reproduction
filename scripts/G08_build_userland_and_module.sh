#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G08 - Build Lattice userland + kernel module, load teectl.ko in guest
# Host (cross, pinned toolchain, offline):
#   a. runtime  -> runtime.bin   (enclave runtime, riscv64imac none-elf; = "fw-rt.bin")
#   b. client   -> client        (host-side launcher, riscv64gc linux-gnu)
#   c. test_launcher             (parallel launcher used for multi-enclave runs)
#   d. tests/enclave/hello.c -> hello (static riscv64 Linux ELF, our own test payload)
#   e. stage: work/stage/lattice/{client,fw-rt.bin,hello,config.toml,tee_mod/}
# Guest (Ubuntu 24.04.5, kernel built in-guest exactly like upstream Makefile):
#   f. boot VM, copy stage over SSH (tar stream)
#   g. `make build` in tee_mod -> teectl.ko ; insmod ; check /dev/teectl
#   h. sanity-run client --help ; poweroff
# Usage   : bash scripts/G08_build_userland_and_module.sh
# Writes  : work/Lattice/target/*, work/stage/, tests/enclave/hello.c (if absent),
#           logs/G08_*.log, logs/GATE_LEDGER.md
# Note    : upstream teectl has no module_exit -> cannot be rmmod'ed; it is
#           loaded fresh after every boot.
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
WORK="$PROJ/work/Lattice"
STAGE="$PROJ/work/stage/lattice"
LOGDIR="$PROJ/logs"
GATE="G08"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_userland_module_${TS}.log"
SERIAL="$LOGDIR/${GATE}_userland_module_${TS}_serial.log"
LEDGER="$LOGDIR/GATE_LEDGER.md"
GNU_TGT="riscv64gc-unknown-linux-gnu"
ELF_TGT="riscv64imac-unknown-none-elf"

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
runlog() {  # runlog <tag> <cmd> : full output to its own log, tail + warning tally in main log
  local tag="$1"; shift
  local f="$LOGDIR/${GATE}_userland_module_${TS}_${tag}.log"
  printf '\n$ %s\n(full output -> logs/%s)\n' "$*" "$(basename "$f")"
  bash -o pipefail -c "$*" 2>&1 | sanitize > "$f"; local r=${PIPESTATUS[0]}
  grep -E '^\s+Finished|^error(\[|:)' "$f" | head -20
  echo "warning tally:"; grep -E '^warning: ' "$f" | sed -E 's/`[^`]*`/X/g' | sort | uniq -c | sort -rn | head -5
  printf '(exit=%s)\n' "$r"; return $r
}
finish() {
  sec "SUMMARY"; printf '%s\n' "${SUMMARY[@]}"
  NF=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[FAIL\]'); NW=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[WARN\]')
  echo; echo "RESULT: FAIL=$NF WARN=$NW"
}

host_build() {
  # shellcheck disable=SC1091
  source "$PROJ/env.sh" || { fail "env.sh missing"; return 1; }
  export CARGO_NET_OFFLINE=true
  run "git -C '$WORK' log --oneline -3"
  [ -z "$(git -C "$WORK" status --porcelain --untracked-files=no)" ] && ok "work tree (tracked files) clean" || warn "work tree has local changes"

  sec "a. Enclave runtime (runtime/Makefile, release)"
  runlog runtime "cd '$WORK/runtime' && make build" && ok "runtime built" || fail "runtime build"
  local rtbin="$WORK/target/$ELF_TGT/release/runtime.bin"
  [ -s "$rtbin" ] && ok "runtime.bin ($(stat -c %s "$rtbin") bytes)" || fail "runtime.bin missing"
  run "riscv64-unknown-linux-gnu-readelf -h '$WORK/target/$ELF_TGT/release/runtime' | grep -E 'Machine|Entry'"

  sec "b. Host-side client (crates/client, release)"
  runlog client "cd '$WORK/crates/client' && cargo build --release --locked" && ok "client built" || fail "client build"
  local cl="$WORK/target/$GNU_TGT/release/client"
  [ -x "$cl" ] && ok "client binary present" || fail "client binary missing"
  run "file '$cl'"

  sec "c. test_launcher (crates/test_launcher, release)"
  runlog test_launcher "cd '$WORK/crates/test_launcher' && cargo build --release --locked" && ok "test_launcher built" || warn "test_launcher build failed (optional)"
  run "file '$WORK/target/$GNU_TGT/release/test_launcher'"

  sec "d. Test payload: tests/enclave/hello.c (static riscv64 Linux ELF)"
  mkdir -p "$PROJ/tests/enclave"
  if [ ! -f "$PROJ/tests/enclave/hello.c" ]; then
    cat > "$PROJ/tests/enclave/hello.c" <<'EOF'
/* Minimal enclave payload for the Lattice LUE smoke test (reproduction harness). */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    const char *msg = "LATTICE_ENCLAVE_HELLO: write(2) via runtime syscall proxy\n";
    write(1, msg, strlen(msg));
    unsigned long sum = 0;
    for (unsigned long i = 0; i < 1000000UL; i++) sum += i;
    printf("LATTICE_ENCLAVE_SUM=%lu\n", sum);   /* expected 499999500000 */
    fflush(stdout);
    return 0;
}
EOF
    echo "created tests/enclave/hello.c"
  fi
  mkdir -p "$PROJ/work/stage"
  run "riscv64-unknown-linux-gnu-gcc -static -O2 -o '$PROJ/work/stage/hello' '$PROJ/tests/enclave/hello.c'" \
    && ok "hello (static) built" || fail "hello build"
  run "file '$PROJ/work/stage/hello'"

  if git -C "$WORK" diff --quiet -- Cargo.lock; then ok "Cargo.lock unchanged by builds"; else fail "Cargo.lock modified by builds"; fi

  sec "e. Stage directory"
  rm -rf "$STAGE"; mkdir -p "$STAGE/tee_mod"
  cp "$cl" "$STAGE/client"
  cp "$rtbin" "$STAGE/fw-rt.bin"
  cp "$PROJ/work/stage/hello" "$STAGE/hello"
  cp "$WORK/target/$GNU_TGT/release/test_launcher" "$STAGE/" 2>/dev/null
  cp "$WORK/linux/modules/tee_mod/main.c" "$WORK/linux/modules/tee_mod/Makefile" "$STAGE/tee_mod/"
  # config.toml derived from upstream crates/client/example.toml (binary -> ./hello)
  sed 's#"./testcode"#"./hello"#' "$WORK/crates/client/example.toml" > "$STAGE/config.toml"
  run "cat '$STAGE/config.toml'"
  ( cd "$STAGE" && find . -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
  run "cat '$STAGE/SHA256SUMS'"
}

guest_part() {
  sec "f. Boot guest"
  local t0; t0=$(date +%s)
  vm_start "$SERIAL" && ok "QEMU started" || { fail "QEMU start"; return 1; }
  if vm_wait_ssh 900; then ok "SSH up after $(( $(date +%s)-t0 )) s"; else fail "SSH not reachable"; vm_stop; return 1; fi
  gssh 'uname -r; nproc'

  sec "g. Copy stage to guest (~/lattice)"
  if tar -C "$STAGE" -cf - . | vm_ssh 'rm -rf ~/lattice && mkdir -p ~/lattice && tar -C ~/lattice -xf -'; then ok "stage copied"; else fail "copy stage"; fi
  if gssh 'cd ~/lattice && sha256sum -c --quiet SHA256SUMS && echo checksums-OK'; then ok "stage checksums verified in guest"; else fail "stage checksum mismatch in guest"; fi

  sec "h. Build teectl.ko in guest (upstream: make build)"
  if gssh 'cd ~/lattice/tee_mod && make build 2>&1 | tail -25 && ls -l teectl.ko'; then ok "teectl.ko built in guest"; else fail "teectl.ko build"; fi
  gssh 'cd ~/lattice/tee_mod && make build 2>&1 | grep -ciE "warning:" ; modinfo ./teectl.ko | grep -E "^(name|vermagic|license|description)"'

  sec "i. Load module"
  if gssh 'sudo insmod ~/lattice/tee_mod/teectl.ko && lsmod | grep -w teectl && ls -l /dev/teectl'; then ok "teectl loaded, /dev/teectl present"
  else fail "insmod teectl / device node"; fi
  gssh 'sudo dmesg | tail -15'
  gssh 'sudo dmesg --level=err,crit,alert,emerg | tail -10'

  sec "j. Userland sanity in guest"
  gssh 'cd ~/lattice && ldd ./client | head; ./client --help' && ok "client runs in guest (--help)" || fail "client does not run in guest"
  gssh 'cd ~/lattice && ./hello'   # reference output outside the enclave (plain static ELF)

  sec "k. Shutdown"
  vm_stop; vm_running && fail "VM still running" || ok "VM stopped"
}

main() {
  sec "META"; echo "gate=$GATE timestamp_utc=$TS"
  host_build
  if printf '%s\n' "${SUMMARY[@]}" | grep -qE '^\[FAIL\] (runtime|client|hello)'; then
    echo "host build failed -> guest part skipped"; finish; return; fi
  guest_part
  finish
}

main 2>&1 | sanitize | tee "$LOG"
if [ -f "$SERIAL" ]; then
  tmp="$(mktemp)"; tr -d '\r' < "$SERIAL" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | sanitize > "$tmp" && cat "$tmp" > "$SERIAL"; rm -f "$tmp"
fi
RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')
echo "| $GATE | Build userland + teectl.ko, load in guest | $TS | ${RES:-ABORTED} | $(basename "$LOG") | - |" >> "$LEDGER"
echo; echo ">>> Logs: logs/${GATE}_userland_module_${TS}*.log"
echo ">>> Please upload the main log (and the _client/_runtime logs if a build failed)."
