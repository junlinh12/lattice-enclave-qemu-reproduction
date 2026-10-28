# =============================================================================
# scripts/lib/vm.sh - QEMU guest helpers for lattice-enclave-qemu-reproduction
# Usage: source scripts/lib/vm.sh
# Machine config mirrors upstream Lattice Makefile `qemu` target:
#   -machine virt -bios fw_payload.bin -m 4096M -smp 4
#   -drive <rootfs>,format=raw,if=virtio  -netdev user + virtio-net-pci
# Differences (harness only, guest-visible hardware unchanged except seed disk):
#   serial -> file instead of stdio, QMP-less HMP monitor on a unix socket,
#   -daemonize, SSH port-forward bound to 127.0.0.1, read-only cloud-init seed.
# =============================================================================
VM_PROJ="${VM_PROJ:-$HOME/projects/lattice-enclave-qemu-reproduction}"
VM_RUN="$VM_PROJ/work/run"
VM_FW="${VM_FW:-$VM_PROJ/work/Lattice/build/qemu-virt/fw_payload.bin}"
VM_DISK="${VM_DISK:-$VM_PROJ/work/images/rootfs.img}"
VM_SEED="${VM_SEED:-$VM_PROJ/work/images/seed.img}"
VM_MEM="${VM_MEM:-4096M}"
VM_SMP="${VM_SMP:-4}"
VM_SSH_PORT="${VM_SSH_PORT:-10022}"
VM_KEY="$VM_PROJ/work/guest/id_ed25519"
VM_KNOWN="$VM_PROJ/work/guest/known_hosts"
VM_SHARE="${VM_SHARE:-}"          # optional host dir exported as 9p tag share0 (upstream `share=`)

vm_running() { [ -f "$VM_RUN/qemu.pid" ] && kill -0 "$(cat "$VM_RUN/qemu.pid" 2>/dev/null)" 2>/dev/null; }

vm_cmdline() {   # prints the exact QEMU command (one arg per line) for the log
  local -a a=(qemu-system-riscv64 -machine virt -m "$VM_MEM" -smp "$VM_SMP" -bios "$VM_FW"
    -drive "file=$VM_DISK,format=raw,if=virtio"
    -drive "file=$VM_SEED,format=raw,if=virtio,readonly=on"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${VM_SSH_PORT}-:22" -device virtio-net-pci,netdev=net0)
  [ -n "$VM_SHARE" ] && a+=(-virtfs "local,path=$VM_SHARE,mount_tag=share0,security_model=mapped-xattr,id=shared0")
  a+=(-display none -serial "file:$1" -monitor "unix:$VM_RUN/monitor.sock,server,nowait"
      -daemonize -pidfile "$VM_RUN/qemu.pid")
  printf '%s\n' "${a[@]}"
}

vm_start() {     # $1 = serial log file
  mkdir -p "$VM_RUN"
  if vm_running; then echo "vm_start: a VM is already running (pid $(cat "$VM_RUN/qemu.pid"))"; return 1; fi
  if ss -ltnH "sport = :${VM_SSH_PORT}" 2>/dev/null | grep -q .; then
    echo "vm_start: TCP port $VM_SSH_PORT busy (set VM_SSH_PORT)"; return 1; fi
  rm -f "$VM_RUN/monitor.sock"
  local -a cmd; mapfile -t cmd < <(vm_cmdline "$1")
  "${cmd[@]}"
}

vm_ssh() {
  ssh -i "$VM_KEY" -p "$VM_SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$VM_KNOWN" -o ConnectTimeout=10 -o ServerAliveInterval=15 \
      -o LogLevel=ERROR ubuntu@127.0.0.1 "$@"
}

vm_wait_ssh() {  # $1 = timeout seconds ; 0=ok 1=timeout 2=VM died
  local t="${1:-600}" s; s=$(date +%s)
  until vm_ssh true 2>/dev/null; do
    vm_running || return 2
    [ $(( $(date +%s) - s )) -ge "$t" ] && return 1
    sleep 10
  done
}

vm_monitor() {   # send one HMP command via the unix socket
  python3 -I -c 'import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.3)
s.sendall((sys.argv[2]+"\n").encode()); time.sleep(0.5); s.close()' "$VM_RUN/monitor.sock" "$1"
}

vm_stop() {      # graceful poweroff, then HMP quit, then SIGTERM
  vm_running || { echo "vm_stop: not running"; return 0; }
  local pid; pid=$(cat "$VM_RUN/qemu.pid")
  vm_ssh 'sudo systemctl poweroff' >/dev/null 2>&1 || true
  for _ in $(seq 1 36); do kill -0 "$pid" 2>/dev/null || { echo "vm_stop: guest powered off"; return 0; }; sleep 5; done
  echo "vm_stop: graceful poweroff timed out -> HMP quit"; vm_monitor quit 2>/dev/null
  sleep 5; kill -0 "$pid" 2>/dev/null && { echo "vm_stop: SIGTERM"; kill "$pid"; }
  return 0
}
