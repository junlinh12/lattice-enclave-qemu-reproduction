#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G11 (v1) - Root-cause fix: reserve SM heap + PMA region in the DT
# Evidence (G10 20261028T061245Z, unpatched SM):
#   all 4 harts spinning at the same kernel pc, mcause=7 (store/AMO access
#   fault -> PMP), mtval = linear-map VAs of PA 0x800a0000/0x800a1000 (SM heap
#   0x800a0000-0x800b0000) and 0x800df000/0x800e1000/0x800e2000 (SM PMA area
#   0x800b0000-0x800f0000). Source: crates/sm/src/platform.rs places heap/PMA
#   right after the OpenSBI region and init_pma() denies host access, but the
#   DT update step in init.rs is commented out, so Linux treats the pages as
#   free RAM and, under memory pressure, faults forever on them.
# Fix (patch 0003, ~25 lines, crates/sm/src/init.rs): after init_pma(), extend
#   OpenSBI's reserved-memory node that ends at the SBI region end so it also
#   covers [heap.start, pma.end), using the existing (unused) upstream helper
#   DeviceInfo::update_reserved_mem_region_size().
# Then: rebuild firmware, boot, verify the DT reservation in Linux, and repeat
#   the G10 memory-pressure experiment with host-side timeouts + automatic
#   CPU-state capture. Also maps the LSE holder's pages (pagemap) before killing
#   it, to test the second hypothesis (LSE pages stay protected after exit).
# Usage   : bash scripts/G11_fix_sm_reserved_memory.sh    (~15 min)
# Needs   : scripts/lib/vm.sh, tests/tools/pagemap.py (cp pagemap.py tests/tools/)
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
WORK="$PROJ/work/Lattice"
PLAT="$WORK/platform/qemu-virt"
BUILD="$WORK/build/qemu-virt"
STAGE="$PROJ/work/stage/lattice"
PATCHDIR="$PROJ/patches/lattice"
LOGDIR="$PROJ/logs"
GATE="G11"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_fix_${TS}.log"
SERIAL="$LOGDIR/${GATE}_fix_${TS}_serial.log"
LEDGER="$LOGDIR/GATE_LEDGER.md"
BASE="05664a26af63e0898828a37b4387efc188388dbf"
GITID=(-c user.name="lattice-repro" -c user.email="repro@localhost" -c commit.gpgsign=false)
export GIT_COMMITTER_DATE="2025-05-26T00:00:00+00:00" GIT_AUTHOR_DATE="2025-05-26T00:00:00+00:00"
# shellcheck disable=SC1091
source "$PROJ/fw_params.env"          # SM_TEXT_START FW_TEXT_START PMP_COUNT
HEAP_START=0x800a0000; PMA_END=0x800f0000   # from G10 evidence / platform.rs sizes
FW_ELF="$BUILD/opensbi/build/platform/generic/firmware/fw_payload.elf"
ART_NEW="$PROJ/work/artifacts/fw-release-0003"

# shellcheck disable=SC1091
source "$PROJ/scripts/lib/vm.sh" || { echo "scripts/lib/vm.sh missing"; exit 1; }
mkdir -p "$LOGDIR" "$ART_NEW"

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
# gssh_t <seconds> <guest command> : host-side hard timeout (does not rely on SSH keepalive)
gssh_t() { local t="$1"; shift; printf '\n[guest, host-timeout %ss]$ %s\n' "$t" "$*"
  timeout -k 10 "$t" bash -c 'source "$0"; vm_ssh "$1"' "$PROJ/scripts/lib/vm.sh" "$*" 2>&1; local r=$?; printf '(exit=%s)\n' "$r"; return $r; }
finish() {
  sec "SUMMARY"; printf '%s\n' "${SUMMARY[@]}"
  NF=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[FAIL\]'); NW=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[WARN\]')
  echo; echo "RESULT: FAIL=$NF WARN=$NW"
}
cpu_state() {  # cpu_state <tag> : dump vCPU regs via HMP, decode mtval -> PA (Sv48 linear map)
  local f="$LOGDIR/${GATE}_fix_${TS}_cpu_state_$1.log"
  python3 -I - "$VM_RUN/monitor.sock" > "$f" 2>&1 <<'PY'
import socket, sys, time, re
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(3)
def rd():
    b = b""
    try:
        while True:
            d = s.recv(65536)
            if not d: break
            b += d
    except socket.timeout: pass
    return b.decode(errors="replace")
rd(); s.sendall(b"info registers -a\n"); time.sleep(1)
for l in rd().splitlines():
    l = l.strip()
    if re.search(r"CPU#|\bpc\b|mhartid|mepc|mcause|mtval |scause|stval", l): print(l)
    m = re.match(r"mtval\s+([0-9a-f]+)", l)
    if m:
        v = int(m.group(1), 16); base = 0xffffaf8000000000
        if v >= base: print(f"  -> PA {v - base + 0x80000000:#x} (Sv48 linear map)")
PY
  echo "cpu state -> logs/$(basename "$f")"; grep -E 'mcause|-> PA' "$f" | sort | uniq -c
}
hard_stop() { cpu_state "$1"; vm_monitor quit 2>/dev/null; sleep 3; vm_running && kill "$(cat "$VM_RUN/qemu.pid")"; sleep 2; vm_running && kill -9 "$(cat "$VM_RUN/qemu.pid")"; echo "QEMU hard-stopped"; }

apply_patch() {
  sec "1. Patch 0003: reserve SM heap + PMA in the DT (crates/sm/src/init.rs)"
  local f="$WORK/crates/sm/src/init.rs"
  if grep -q '\[repro 0003\]' "$f"; then echo "already applied"; ok "patch 0003 present"; return 0; fi
  python3 -I - "$f" <<'PY' || return 1
import sys
p = sys.argv[1]; s = open(p).read()
old_dev = "    let device = DeviceInfo::new(fdt as *const u8).unwrap();\n"
anchor = '    init_pma(sm, platform);\n    log::debug!("Inited pma");\n'
assert old_dev in s and anchor in s, "anchors not found"
s = s.replace(old_dev, "    let mut device = DeviceInfo::new(fdt as *const u8).unwrap();\n", 1)
fix = anchor + '''
    // [repro 0003] Reserve the SM heap + PMA region in the device tree handed
    // to the next stage. init_pma() makes these pages inaccessible to the host
    // via PMP, but the DT update step ("update the reserved memory area",
    // commented out below) is missing upstream, so Linux treats them as free
    // RAM and, under memory pressure, spins forever on store access faults
    // (mcause=7). Extend OpenSBI's reserved-memory node that ends at the SBI
    // region end so that it also covers [heap.start, pma.end).
    {
        let sbi = platform.get_sbi_region();
        let heap = platform.get_heap_region();
        let pma = platform.get_pma_region();
        log::info!("[repro] sbi {:#x?} heap {:#x?} pma {:#x?}", sbi, heap, pma);
        // find the reserved-memory node (created by OpenSBI) that ends where
        // the SM heap begins, then grow it up to the end of the PMA area
        let mut node_start: Option<usize> = None;
        if let Some(rm) = device.fdt.find_node("/reserved-memory") {
            for child in rm.children() {
                if let Some(r) = child.reg().and_then(|mut it| it.next()) {
                    let s = r.starting_address as usize;
                    let e = s + r.size.unwrap_or(0);
                    if e == sbi.end && s < sbi.end {
                        node_start = Some(s);
                        break;
                    }
                }
            }
        }
        match node_start
            .and_then(|s| device.update_reserved_mem_region_size(s, pma.end - s).map(|_| s))
        {
            Some(s) => log::info!(
                "[repro] reserved-memory {:#x}..{:#x} extended to {:#x} (SM heap+PMA)",
                s,
                sbi.end,
                pma.end
            ),
            None => log::warn!("[repro] SM heap/PMA {:#x}..{:#x} NOT reserved in DT", sbi.end, pma.end),
        }
    }
'''
s = s.replace(anchor, fix, 1)
open(p, "w").write(s)
PY
  run "git -C '$WORK' diff --stat"
  git -C "$WORK" add crates/sm/src/init.rs
  git "${GITID[@]}" -C "$WORK" commit -q -F - <<'MSG'
repro: sm - reserve SM heap and PMA region in the device tree

init_pma() denies host (S/U-mode) access to the SM heap and PMA metadata
area that platform.rs places directly after the OpenSBI region
(0x800a0000-0x800f0000 on qemu-virt), but the step that should publish
this to the next stage ("update the reserved memory area") is commented
out. Linux therefore treats the pages as free RAM; once the page
allocator hands them out (memory pressure, shutdown), every hart spins
on store access faults (mcause=7) and the system hangs.

Extend OpenSBI's reserved-memory node that ends at the SBI region end so
that it also covers the heap and PMA area, using the existing helper
DeviceInfo::update_reserved_mem_region_size(); the node is located
by parsing /reserved-memory for the entry that ends at the SBI region end.
MSG
  ok "patch 0003 committed"
}

main() {
  sec "META"; echo "gate=$GATE (v1) timestamp_utc=$TS SM_TEXT_START=$SM_TEXT_START"
  # shellcheck disable=SC1091
  source "$PROJ/env.sh" || { fail "env.sh missing"; finish; return; }
  export CARGO_NET_OFFLINE=true
  [ -f "$PROJ/tests/tools/pagemap.py" ] && ok "tests/tools/pagemap.py present" || { fail "copy pagemap.py to tests/tools/ first"; finish; return; }

  apply_patch || { fail "patch 0003 could not be applied"; finish; return; }
  rm -f "$PATCHDIR"/0*.patch
  run "git -C '$WORK' format-patch -q --no-signature -o '$PATCHDIR' $BASE..HEAD && ls -1 '$PATCHDIR'"

  # --------------------------------------------------------------------------- 2. firmware
  sec "2. Rebuild firmware (upstream firmware.mk, release)"
  local blog="$LOGDIR/${GATE}_fix_${TS}_fw_build.log"
  ( cd "$WORK" && make -f "$PLAT/firmware.mk" build_path="$BUILD" platform_path="$PLAT" profile=release \
      SM_TEXT_START=$SM_TEXT_START FW_TEXT_START=$FW_TEXT_START PMP_COUNT=$PMP_COUNT firmware ) 2>&1 | sanitize > "$blog"
  local rc=${PIPESTATUS[0]}
  grep -E '^error|^\s+Finished|GEN opensbi' "$blog"; echo "(make exit=$rc, full log -> logs/$(basename "$blog"))"
  if [ "$rc" -ne 0 ]; then fail "firmware rebuild (see build log; patch 0003 may not compile)"; grep -A12 '^error' "$blog" | head -40; finish; return; fi
  ok "firmware rebuilt with patch 0003"
  git -C "$WORK" diff --quiet -- Cargo.lock && ok "Cargo.lock unchanged" || fail "Cargo.lock modified"
  local smi; smi=$(riscv64-unknown-linux-gnu-nm "$FW_ELF" | awk '$3=="sm_init"{print "0x"$1}')
  echo "sm_init=$smi expected=$SM_TEXT_START"
  [ "$((smi))" -eq "$((SM_TEXT_START))" ] && ok "sm_init still at SM_TEXT_START" || { fail "sm_init moved ($smi) - rerun G05 logic"; finish; return; }
  riscv64-unknown-linux-gnu-objcopy -O binary --only-section=.sm "$FW_ELF" "$ART_NEW/.sm"
  cmp -n "$(stat -c %s "$BUILD/sm.bin")" "$ART_NEW/.sm" "$BUILD/sm.bin" >/dev/null && ok "embedded .sm == new sm.bin" || fail "embedded .sm differs"
  rm -f "$ART_NEW/.sm"
  strings "$BUILD/sm.bin" | grep -q '\[repro\] reserved-memory' && ok "patched SM string present in sm.bin" || fail "patch string not in sm.bin"
  cp -f "$BUILD"/fw_payload.bin "$BUILD/sm.bin" "$FW_ELF" "$ART_NEW/"; ( cd "$ART_NEW" && sha256sum * > SHA256SUMS ); run "cat '$ART_NEW/SHA256SUMS'"

  # --------------------------------------------------------------------------- 3. boot + DT check
  sec "3. Boot patched firmware, verify reservation"
  cp -f "$PROJ/tests/tools/pagemap.py" "$STAGE/pagemap.py"
  ( cd "$STAGE" && find . -type f ! -name 'SHA256SUMS*' ! -name '*.out' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS )
  local t0; t0=$(date +%s)
  vm_start "$SERIAL" && ok "QEMU started" || { fail "QEMU start"; finish; return; }
  if ! timeout 960 bash -c 'source "$0"; vm_wait_ssh 900' "$PROJ/scripts/lib/vm.sh"; then fail "SSH not reachable (boot regression?)"; hard_stop boot; finish; return; fi
  ok "SSH up after $(( $(date +%s)-t0 )) s"
  run "tr -d '\r' < '$SERIAL' | grep -a '\[repro\]'" && ok "SM logged the DT reservation" || fail "no [repro] line on console"
  gssh_t 60 'for n in /proc/device-tree/reserved-memory/*/; do printf "%-28s " "$(basename $n)"; python3 -c "import sys,struct; a,s=struct.unpack(\">QQ\", open(sys.argv[1],\"rb\").read()[:16]); print(hex(a), \"-\", hex(a+s))" "$n/reg"; done; sudo dmesg | grep -i "reserved mem" | head'
  if timeout 60 bash -c 'source "$0"; vm_ssh "$1"' "$PROJ/scripts/lib/vm.sh" \
     "for n in /proc/device-tree/reserved-memory/*/reg; do python3 -c \"import sys,struct; a,s=struct.unpack('>QQ', open(sys.argv[1],'rb').read()[:16]); print(1 if a<=$HEAP_START and a+s>=$PMA_END else 0)\" \$n; done | grep -q 1"; then
    ok "Linux sees a reserved-memory node covering $HEAP_START-$PMA_END"
  else fail "SM heap/PMA not covered by reserved-memory in Linux"; fi

  # --------------------------------------------------------------------------- 4. experiment
  sec "4. Re-run G10 memory-pressure experiment"
  tar -C "$STAGE" -cf - . | timeout 120 bash -c 'source "$0"; vm_ssh "rm -rf ~/lattice && mkdir -p ~/lattice && tar -C ~/lattice -xf -"' "$PROJ/scripts/lib/vm.sh"
  gssh_t 120 'cd ~/lattice && sha256sum -c --quiet SHA256SUMS && echo checksums-OK && cd tee_mod && make build >/dev/null 2>&1 && sudo insmod teectl.ko && ls -l /dev/teectl' || { fail "stage/teectl"; hard_stop setup; finish; return; }
  gssh_t 180 'cd ~/lattice && sudo sh -c "nohup ./client --lse -c config.toml > lse.out 2>&1 < /dev/null &"; for i in $(seq 1 60); do grep -q "lse created" lse.out 2>/dev/null && break; sleep 2; done; tail -2 lse.out'
  gssh_t 300 'cd ~/lattice && for i in 1 2 3 4 5; do sudo timeout 120 ./client -c config.toml ./hello 2>&1 | grep -c "enclave finished"; done; sudo timeout 300 ./test_launcher "./client -c config.toml ./hello" 8 2>&1 | grep -c "enclave finished"' \
    && ok "pre-condition: 5 sequential + 8 parallel LUEs executed" || { fail "LUE runs"; hard_stop lue; finish; return; }

  local mb out
  mb=$(timeout 60 bash -c 'source "$0"; vm_ssh "$1"' "$PROJ/scripts/lib/vm.sh" "sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'; awk '/MemAvailable/ {printf \"%d\", \$2/1024*0.85}' /proc/meminfo")
  echo "fill size = 85% of MemAvailable = ${mb} MB"
  sec "4a. Control: memfill with LSE alive (this hung in G10)"
  out=$(gssh_t 420 "cd ~/lattice && timeout 300 ./memfill $mb; echo __RC=\$?"); local r=$?; echo "$out"
  if echo "$out" | grep -q 'MEMFILL_OK' && echo "$out" | grep -q '__RC=0'; then ok "M-A memfill ${mb} MB with LSE alive: OK (G10 hang fixed by patch 0003)"
  else fail "M-A memfill failed/hung (rc=$r)"; hard_stop MA; finish; return; fi
  gssh_t 120 "cd ~/lattice && free -m | head -2 && sudo dmesg | grep -iE 'Oops|BUG:|lockup|stall' | tail -3"

  sec "4b. LSE holder exit: map its pages, kill it, memfill again"
  gssh_t 60 'cd ~/lattice && pid=$(pgrep -f "[c]lient --lse"); r=$(grep "memory region" lse.out | awk "{print \$3, \$5}"); echo "pid=$pid region=$r"; sudo python3 pagemap.py $pid $r | tee lse_pages.txt'
  gssh_t 60 'sudo pkill -f "[c]lient --lse"; sleep 2; pgrep -af "[c]lient --lse" || echo "LSE holder gone"'
  out=$(gssh_t 420 "cd ~/lattice && timeout 300 ./memfill $mb; echo __RC=\$?"); r=$?; echo "$out"
  if echo "$out" | grep -q 'MEMFILL_OK'; then
    info "M-B memfill after LSE exit succeeded -> LSE-page hypothesis NOT supported"
    sec "5. Graceful shutdown"
    local so; so=$(vm_stop 2>&1); echo "$so"
    if echo "$so" | grep -q 'guest powered off'; then ok "graceful poweroff completed"; else warn "graceful poweroff did not complete"; hard_stop shutdown; fi
  else
    info "M-B memfill after LSE exit hung (rc=$r) -> freed LSE pages remain SM-protected (no LSE destroy path)"
    hard_stop MB
    echo "compare: faulting PA (cpu_state_MB) vs LSE pages recorded before kill (lse_pages.txt, shown above)"
  fi
  vm_running && fail "VM still running" || ok "VM stopped"

  sec "6. Serial: SM lines"
  tr -d '\r' < "$SERIAL" | grep -anE '\[repro\]|panicked|\[Warning\]|\[Error\]|Oops|lockup|stall' | head -40
  finish
}

main 2>&1 | sanitize | tee "$LOG"
if [ -f "$SERIAL" ]; then
  tmp="$(mktemp)"; tr -d '\r' < "$SERIAL" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | sanitize > "$tmp" && cat "$tmp" > "$SERIAL"; rm -f "$tmp"
fi
RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')
echo "| $GATE | Fix: reserve SM heap+PMA in DT (patch 0003) + re-test | $TS | ${RES:-ABORTED} | $(basename "$LOG") | - |" >> "$LEDGER"
echo; echo ">>> Logs: logs/${GATE}_fix_${TS}*.log"
echo ">>> Please upload the main log, _serial.log and any _cpu_state_*.log."
