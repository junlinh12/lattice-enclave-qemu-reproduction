#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G06 - Prepare the riscv64 guest root filesystem
# What    :
#   1. Download Ubuntu 24.04.5 preinstalled server (riscv64) + SHA256SUMS(.gpg)
#      + manifest from cdimage.ubuntu.com; verify SHA256 (+ GPG if keyring found)
#   2. Decompress to work/images/rootfs.img and grow it to 32 GiB (sparse)
#   3. Create a project-only SSH key + random console password (never logged)
#   4. Build a cloud-init NoCloud seed (seed.img): user "ubuntu", key login,
#      build-essential + linux-headers-$(uname -r) (needed to build teectl.ko
#      inside the guest, as upstream linux/modules/tee_mod/Makefile expects)
# Why Ubuntu 24.04: upstream Makefile boots a raw virtio disk via U-Boot; the
#   tee_mod Makefile builds against /lib/modules/$(uname -r)/build inside the
#   guest, so a distro with installable kernel headers is required. 24.04 does
#   not require RVA23 (25.10+ does, which QEMU 8.2 cannot emulate).
# Prereq  : sudo apt install -y cloud-image-utils     (provides cloud-localds)
# Usage   : bash scripts/G06_prepare_guest_rootfs.sh
# Writes  : work/images/*, work/guest/* (secrets, gitignored), logs/G06_*.log
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
IMGDIR="$PROJ/work/images"
GUEST="$PROJ/work/guest"
LOGDIR="$PROJ/logs"
GATE="G06"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_guest_rootfs_${TS}.log"
LEDGER="$LOGDIR/GATE_LEDGER.md"

BASEURL="https://cdimage.ubuntu.com/releases/noble/release"
IMG="ubuntu-24.04.5-preinstalled-server-riscv64.img.xz"
MANIFEST="ubuntu-24.04.5-preinstalled-server-riscv64.manifest"
ROOTFS="$IMGDIR/rootfs.img"
ROOTFS_SIZE="32G"

mkdir -p "$LOGDIR" "$IMGDIR" "$GUEST"
chmod 700 "$GUEST"

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

finish() {
  sec "SUMMARY"; printf '%s\n' "${SUMMARY[@]}"
  NF=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[FAIL\]'); NW=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[WARN\]')
  echo; echo "RESULT: FAIL=$NF WARN=$NW"
}

main() {
  sec "META"; echo "gate=$GATE timestamp_utc=$TS image=$IMG"

  # --------------------------------------------------------------------------- 0. prereqs
  sec "0. Prerequisites"
  local miss=0
  for t in curl xz sha256sum qemu-img ssh-keygen openssl cloud-localds fdisk; do
    if command -v "$t" >/dev/null 2>&1; then echo "ok      $t"; else echo "MISSING $t"; miss=1; fi
  done
  if [ $miss -ne 0 ]; then fail "missing tools (install: sudo apt install -y cloud-image-utils)"; finish; return; fi
  ok "all tools present"
  if grep -qxF 'work/' "$PROJ/.gitignore" 2>/dev/null; then ok "work/ is gitignored (secrets stay local)"
  else fail "work/ not in .gitignore - refusing to create secrets"; finish; return; fi
  run "df -h '$IMGDIR' | tail -1"

  # --------------------------------------------------------------------------- 1. download + verify
  sec "1. Download & verify"
  ( cd "$IMGDIR" && for f in SHA256SUMS SHA256SUMS.gpg "$MANIFEST"; do
      curl -fsSL --retry 3 -o "$f" "$BASEURL/$f" || exit 1; done ) \
    && ok "SHA256SUMS, .gpg, manifest downloaded" || { fail "metadata download"; finish; return; }

  # GPG signature of SHA256SUMS (Ubuntu CD image signing key)
  local gpgok=0
  for kr in /usr/share/keyrings/ubuntu-archive-keyring.gpg /usr/share/keyrings/ubuntu-master-keyring.gpg /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg; do
    [ -f "$kr" ] || continue
    if gpgv --keyring "$kr" "$IMGDIR/SHA256SUMS.gpg" "$IMGDIR/SHA256SUMS" >/dev/null 2>&1; then
      echo "SHA256SUMS signature valid with $(basename "$kr")"; gpgok=1; break; fi
  done
  [ $gpgok -eq 1 ] && ok "SHA256SUMS GPG signature verified" || warn "SHA256SUMS signature not verified (no matching local keyring); SHA256 still checked"

  local want; want=$(grep " \*\?$IMG\$" "$IMGDIR/SHA256SUMS" | awk '{print $1}')
  echo "expected sha256($IMG) = $want"
  [ -n "$want" ] || { fail "image not listed in SHA256SUMS"; finish; return; }

  if [ -f "$IMGDIR/$IMG" ] && echo "$want  $IMGDIR/$IMG" | sha256sum -c --status; then
    echo "image already downloaded and verified -> skip"
  else
    echo "downloading $IMG (~1.2 GB) ..."
    ( cd "$IMGDIR" && curl -fL --retry 3 -C - -o "$IMG" "$BASEURL/$IMG" ) 2>&1 | tr '\r' '\n' | tail -n 2
  fi
  if echo "$want  $IMGDIR/$IMG" | sha256sum -c --status; then ok "image SHA256 verified"; else fail "image SHA256 mismatch"; finish; return; fi

  sec "1b. Guest software baseline (from official manifest)"
  run "grep -E '^(linux-image-|linux-generic|linux-riscv|cloud-init|grub-efi-riscv64|openssh-server|u-boot)' '$IMGDIR/$MANIFEST'"

  # --------------------------------------------------------------------------- 2. rootfs
  sec "2. Working disk image"
  if [ -f "$ROOTFS" ]; then
    echo "rootfs.img exists -> keep (delete it manually to regenerate from the verified .xz)"
    warn "reusing existing rootfs.img (may already be booted/modified)"
  else
    run "xz -dk -T0 -c '$IMGDIR/$IMG' > '$ROOTFS'" || { fail "decompress"; finish; return; }
    run "qemu-img resize -f raw '$ROOTFS' $ROOTFS_SIZE" || { fail "resize"; finish; return; }
    ok "rootfs.img created and grown to $ROOTFS_SIZE (root partition grows on first boot via cloud-init)"
  fi
  run "qemu-img info '$ROOTFS'"
  run "fdisk -l '$ROOTFS' 2>/dev/null | sed -n '1,20p'"

  # --------------------------------------------------------------------------- 3. credentials
  sec "3. Project-only guest credentials (values are NOT logged)"
  if [ ! -f "$GUEST/id_ed25519" ]; then
    ssh-keygen -q -t ed25519 -N "" -C "lattice-repro-guest" -f "$GUEST/id_ed25519" && ok "SSH key generated"
  else ok "SSH key exists"; fi
  if [ ! -f "$GUEST/console_password" ]; then
    ( umask 077; openssl rand -base64 18 | tr -d '/+=' > "$GUEST/console_password" ) && ok "console password generated"
  else ok "console password exists"; fi
  chmod 600 "$GUEST/id_ed25519" "$GUEST/console_password"
  run "ssh-keygen -lf '$GUEST/id_ed25519.pub'"
  echo "console password stored in work/guest/console_password (mode 600, not printed)"

  # --------------------------------------------------------------------------- 4. cloud-init seed
  sec "4. cloud-init NoCloud seed"
  local hash pub
  hash=$(openssl passwd -6 -stdin < "$GUEST/console_password")
  pub=$(cat "$GUEST/id_ed25519.pub")
  ( umask 077
  cat > "$GUEST/user-data" <<EOF
#cloud-config
hostname: lattice-guest
users:
  - name: ubuntu
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    passwd: "$hash"
    ssh_authorized_keys:
      - $pub
ssh_pwauth: false
chpasswd:
  expire: false
growpart:
  mode: auto
  devices: ["/"]
package_update: true
packages:
  - build-essential
  - git
runcmd:
  - [ sh, -c, "apt-get install -y linux-headers-\$(uname -r) && touch /var/lib/lattice-headers-ok" ]
final_message: "LATTICE_CLOUD_INIT_DONE after \$UPTIME seconds"
EOF
  cat > "$GUEST/meta-data" <<EOF
instance-id: lattice-guest-001
local-hostname: lattice-guest
EOF
  )
  run "cloud-localds '$IMGDIR/seed.img' '$GUEST/user-data' '$GUEST/meta-data'" && ok "seed.img created" || fail "cloud-localds"
  echo "user-data (password hash and key redacted):"
  sed -E -e 's#(passwd: ).*#\1"<REDACTED>"#' -e 's#(ssh-ed25519) .*#\1 <REDACTED>#' "$GUEST/user-data"

  sec "5. Files"
  run "ls -la '$IMGDIR' '$GUEST' | awk '{print \$1, \$5, \$9}'"
  run "du -sh '$IMGDIR'"
  finish
}

main 2>&1 | sanitize | tee "$LOG"
RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')
echo "| $GATE | Prepare guest rootfs (Ubuntu 24.04.5 riscv64) | $TS | ${RES:-ABORTED} | $(basename "$LOG") | - |" >> "$LEDGER"
echo; echo ">>> Log written: logs/$(basename "$LOG")"; echo ">>> Please upload that log file to the chat."
