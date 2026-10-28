#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G01 - Host environment & resource check (READ-ONLY)
# Usage   : bash G01_host_env_check.sh
# Output  : $HOME/projects/lattice-enclave-qemu-reproduction/logs/
#             G01_host_env_<UTC timestamp>.log   (sanitized at write time)
#             GATE_LEDGER.md                     (appended)
#           $HOME/projects/MAIN_TASK.md          (created only if missing)
# Notes   : - Installs nothing, modifies nothing except the files above.
#           - User name / host name / home path / IP / MAC / e-mail are masked
#             before anything is written, so the log is safe to share/publish.
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
LOGDIR="$PROJ/logs"
GATE="G01"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_host_env_${TS}.log"
LEDGER="$LOGDIR/GATE_LEDGER.md"
MAIN_TASK="$HOME/projects/MAIN_TASK.md"

# Reference values taken from upstream LatticeEnclave/Lattice
UPSTREAM_COMMIT="05664a26af63e0898828a37b4387efc188388dbf"   # main, 2025-05-26
RUST_TC="nightly-2024-11-27"                                  # rust-toolchain.toml
OPENSBI_COMMIT="ef4520b1c63fc2770b10d952a800f9734f861b0a"     # platform/qemu-virt/firmware.mk
PRIOR_SRC="$HOME/Lattice/Lattice-Reproduction-V1/source/Lattice"

mkdir -p "$LOGDIR"

# ----------------------------------------------------------------------------- sanitizer
_U="$(id -un)"
_H="$(hostname 2>/dev/null || echo __nohost__)"
_HS="$(hostname -s 2>/dev/null || echo __nohost__)"
sanitize() {
  sed -E \
    -e "s#${HOME}#\$HOME#g" \
    -e "s#/home/${_U}#\$HOME#g" \
    -e "s#${_H//./\\.}#<HOST>#g" \
    -e "s#\b${_HS}\b#<HOST>#g" \
    -e "s#\b${_U}\b#<USER>#g" \
    -e 's#\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b#<MAC>#g' \
    -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#<EMAIL>#g' \
    -e 's#\b((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\b#<IPV4>#g'
}

# ----------------------------------------------------------------------------- helpers
declare -a SUMMARY=()
ok()   { SUMMARY+=("[PASS] $*"); }
warn() { SUMMARY+=("[WARN] $*"); }
fail() { SUMMARY+=("[FAIL] $*"); }
sec()  { printf '\n==================== %s ====================\n' "$*"; }
run()  { printf '\n$ %s\n' "$*"; timeout 60 bash -c "$*" 2>&1; printf '(exit=%s)\n' "$?"; }
have() { command -v "$1" >/dev/null 2>&1; }

main() {
  sec "META"
  echo "gate=$GATE  timestamp_utc=$TS  script=G01_host_env_check.sh"

  # --------------------------------------------------------------------------- OS
  sec "1. OS / Kernel"
  run "grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release"
  run "uname -srm"
  if grep -q 'VERSION_ID="24.04"' /etc/os-release; then ok "OS: Ubuntu 24.04"; else warn "OS is not Ubuntu 24.04"; fi

  # --------------------------------------------------------------------------- compute
  sec "2. CPU / Memory / Disk"
  run "lscpu | grep -E '^(Architecture|Model name|Socket|Core|Thread|CPU\(s\)|Virtualization)'"
  run "nproc"
  run "free -h"
  run "swapon --show"
  run "df -hT \"\$HOME\" /tmp"
  NP=$(nproc)
  MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
  DISK_GB=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
  [ "$NP" -ge 8 ] && ok "CPU threads: $NP" || warn "CPU threads: $NP (>=8 recommended for kernel/QEMU builds)"
  [ "$MEM_GB" -ge 16 ] && ok "RAM: ${MEM_GB} GiB" || warn "RAM: ${MEM_GB} GiB (>=16 GiB recommended; guest uses 4 GiB)"
  [ "$DISK_GB" -ge 60 ] && ok "Free disk on \$HOME: ${DISK_GB} GiB" || warn "Free disk on \$HOME: ${DISK_GB} GiB (>=60 GiB recommended: rootfs + kernel + builds)"

  # --------------------------------------------------------------------------- base build tools
  sec "3. Base build tools"
  for t in git make gcc g++ python3 bc bison flex dtc cpio rsync curl wget xz zstd qemu-img; do
    if have "$t"; then printf '%-10s %s\n' "$t" "$($t --version 2>&1 | head -1)"; ok "tool: $t"
    else printf '%-10s MISSING\n' "$t"; fail "tool missing: $t"; fi
  done
  sec "3b. Relevant apt packages"
  run "dpkg-query -W -f='\${Status} \${Package} \${Version}\n' build-essential libssl-dev libgnutls28-dev python3-dev swig python3-setuptools python3-pyelftools device-tree-compiler u-boot-tools gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu qemu-system-misc qemu-utils debootstrap libglib2.0-dev libpixman-1-dev ninja-build pkg-config 2>&1 | sed 's/^install ok installed/OK /'"

  # --------------------------------------------------------------------------- RISC-V cross toolchain
  sec "4. RISC-V cross toolchain (firmware.mk default: riscv64-unknown-linux-gnu-)"
  run "type -a riscv64-unknown-linux-gnu-gcc riscv64-linux-gnu-gcc riscv64-unknown-elf-gcc"
  for p in riscv64-unknown-linux-gnu- riscv64-linux-gnu-; do
    if have "${p}gcc"; then run "${p}gcc --version | head -1"; run "${p}objcopy --version | head -1"; fi
  done
  if have riscv64-unknown-linux-gnu-objcopy; then ok "cross: riscv64-unknown-linux-gnu- (Makefile default)"
  elif have riscv64-linux-gnu-objcopy; then warn "cross: only riscv64-linux-gnu- found (usable via CROSS_COMPILE=riscv64-linux-gnu-)"
  else fail "no RISC-V cross toolchain found"; fi

  # --------------------------------------------------------------------------- QEMU
  sec "5. QEMU"
  run "type -a qemu-system-riscv64"
  if have qemu-system-riscv64; then
    run "qemu-system-riscv64 --version | head -1"
    run "qemu-system-riscv64 -machine help | grep -E '^virt'"
    ok "qemu-system-riscv64 present"
  else fail "qemu-system-riscv64 missing"; fi

  # --------------------------------------------------------------------------- Rust
  sec "6. Rust (rust-toolchain.toml: $RUST_TC)"
  run "rustup --version"
  run "rustup toolchain list"
  run "cargo --version"
  if have rustup && rustup toolchain list 2>/dev/null | grep -q "^$RUST_TC"; then
    ok "rust toolchain $RUST_TC installed"
    run "rustup target list --installed --toolchain $RUST_TC"
    run "rustup component list --installed --toolchain $RUST_TC"
    TGT=$(rustup target list --installed --toolchain "$RUST_TC" 2>/dev/null)
    for t in riscv64imac-unknown-none-elf riscv64gc-unknown-linux-gnu; do
      echo "$TGT" | grep -q "^$t$" && ok "rust target $t" || fail "rust target missing: $t"
    done
    CMP=$(rustup component list --installed --toolchain "$RUST_TC" 2>/dev/null)
    for c in rust-src rustfmt clippy llvm-tools; do
      echo "$CMP" | grep -q "^$c" && ok "rust component $c" || warn "rust component missing: $c"
    done
  else fail "rust toolchain $RUST_TC not installed"; fi

  # --------------------------------------------------------------------------- Container / misc
  sec "7. Optional: container & GitHub tooling"
  for t in docker podman gh gitleaks; do
    if have "$t"; then printf '%-9s %s\n' "$t" "$($t --version 2>&1 | head -1)"; else printf '%-9s not installed\n' "$t"; fi
  done
  if git config --global user.email >/dev/null 2>&1; then
    E=$(git config --global user.email)
    case "$E" in *users.noreply.github.com) ok "git identity uses GitHub noreply address";;
                 *) warn "git global user.email is a real address -> use a GitHub noreply address before publishing";; esac
  else warn "git global user.email not set"; fi

  # --------------------------------------------------------------------------- Network
  sec "8. Upstream reachability (read-only ls-remote)"
  for u in https://github.com/LatticeEnclave/Lattice https://github.com/riscv-software-src/opensbi https://github.com/u-boot/u-boot; do
    if timeout 30 git ls-remote "$u" HEAD >/dev/null 2>&1; then echo "reachable   $u"; ok "reachable: $u"
    else echo "UNREACHABLE $u"; fail "unreachable: $u"; fi
  done
  run "timeout 30 git ls-remote https://github.com/LatticeEnclave/Lattice HEAD"
  echo "reference upstream commit used for this plan: $UPSTREAM_COMMIT"
  echo "reference OpenSBI commit (firmware.mk):       $OPENSBI_COMMIT"

  # --------------------------------------------------------------------------- Project state
  sec "9. Current project folder state (names only)"
  run "find \"$PROJ\" -maxdepth 3 -printf '%y %TY-%Tm-%Td %8s %P\n' | sort -k3"
  run "du -sh \"$PROJ\""

  sec "10. Prior Lattice source (reference only, not modified)"
  if [ -d "$PRIOR_SRC/.git" ]; then
    run "git -C \"$PRIOR_SRC\" rev-parse HEAD"
    run "git -C \"$PRIOR_SRC\" status --short | wc -l"
    H=$(git -C "$PRIOR_SRC" rev-parse HEAD 2>/dev/null)
    [ "$H" = "$UPSTREAM_COMMIT" ] && ok "prior source matches upstream $UPSTREAM_COMMIT" \
                                   || warn "prior source HEAD differs from upstream ($H)"
  else echo "not found: $PRIOR_SRC"; fi

  # --------------------------------------------------------------------------- Summary
  sec "SUMMARY"
  printf '%s\n' "${SUMMARY[@]}"
  NF=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[FAIL\]')
  NW=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[WARN\]')
  echo
  echo "RESULT: FAIL=$NF WARN=$NW"
}

# ----------------------------------------------------------------------------- execute
main 2>&1 | sanitize | tee "$LOG"

RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')

# ----------------------------------------------------------------------------- gate ledger
if [ ! -f "$LEDGER" ]; then
  cat > "$LEDGER" <<'EOF'
# Gate Ledger - lattice-enclave-qemu-reproduction

Every 5th gate (G05, G10, ...) is a checkpoint: re-read ../../MAIN_TASK.md and
record whether the current work still serves the main task.

| Gate | Title | UTC time | Result | Log file | Checkpoint |
|------|-------|----------|--------|----------|------------|
EOF
fi
echo "| $GATE | Host environment check | $TS | $RES | $(basename "$LOG") | - |" >> "$LEDGER"

# ----------------------------------------------------------------------------- main task file
if [ ! -f "$MAIN_TASK" ]; then
  cat > "$MAIN_TASK" <<'EOF'
# MAIN TASK (re-read at every 5th gate)

## Phase A - Reproduce on QEMU (host: Ubuntu 24.04)
1. Lattice Enclave  - paper: doi 10.1145/3844614 / code: github.com/LatticeEnclave/Lattice
2. IBM ACE          - paper: arXiv 2505.12995 / code: github.com/IBM/ACE-RISCV
3. RISC-V OP-TEE    - code: gitlab.com/riseproject/riscv-optee

## Phase B - Port all three TEEs to Milk-V Jupiter 2
SpacemiT K3 SoC (RVA23), 32 GB RAM, 128 GB SSD

## Requirements
R1 Publish to github.com/junlinh12 only after sanitizing personal / host-local info.
R2 One Project, One Log System: one log folder per project (Lattice: logs/).
R3 Every 5 gates: re-read this file and confirm no drift from the main task.
R4 Check host environment & resources before starting each new project.
R5 All projects live under ~/projects; never upload host-specific local info.
EOF
  echo "created: ~/projects/MAIN_TASK.md"
fi

echo
echo ">>> Log written: logs/$(basename "$LOG")"
echo ">>> Please upload that log file to the chat."
