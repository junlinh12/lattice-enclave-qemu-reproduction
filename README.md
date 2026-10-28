# Lattice Enclave — Reproduction on QEMU (RISC-V)

Independent, step-by-step reproduction of **Lattice**:

> Y. Zhao, J. He, M. Xu, W. Chen, W. Qiang, D. Zou. *Lattice: Enabling Scalable
> Enclaves for Commercial RISC-V Platforms.* ACM Transactions on Architecture
> and Code Optimization (TACO) 23(4), Article 132, December 2026.
> [doi:10.1145/3844614](https://doi.org/10.1145/3844614) · upstream code:
> [LatticeEnclave/Lattice](https://github.com/LatticeEnclave/Lattice)

The upstream code (commit `05664a2`) is built and run on QEMU `virt` with an
Ubuntu 24.04 riscv64 guest. Section 2 compares what the paper describes with
what the public code implements and what could be reproduced here.

This repository is part A-1 of a larger study that reproduces three RISC-V
TEEs (Lattice, IBM ACE, RISC-V OP-TEE) on QEMU and then ports them to a
Milk-V Jupiter 2 board (SpacemiT K3, RVA23).

---

## 0. Result at a glance

| Item | Outcome | Evidence (`logs/`) |
|---|---|---|
| Build SM, OpenSBI + SM, U-Boot, enclave runtime, client and kernel module from pinned commits | ✅ reproducible (identical `sm.bin` hash across rebuilds) | G04, G05 |
| Non-intrusive SM inside OpenSBI; boot OpenSBI → SM → U-Boot → GRUB → Linux 7.0 on 4 harts | ✅ | G05, G07 |
| Enclaves supported by the public code: service enclave (LSE) and user enclave (LUE) | ✅ run, syscall proxy, clean exit, 30+ sequential runs | G09, G10 |
| 2 / 4 / 8 concurrent enclaves (8 > number of harts) | ✅ all correct | G10 |
| Linux under memory pressure next to the SM | ❌ upstream hangs → ✅ fixed by patch 0003 | G10, G11 |
| Paper's evaluation (rv8, SQLite3, Llama2.c, FSCQ, darkhttpd, 2048 enclaves, cycle counts) | ⚠️ not reproduced: no benchmark harness in the public repo, and QEMU TCG is not cycle-accurate | §2.3 |
| Secure trap proxy (ePMP), driver enclave (LDE) | ⚠️ not present in the public code | §2.2 |

---

## 1. Terminology: paper ↔ public code

| Paper | Public code (`05664a2`) |
|---|---|
| Secure Monitor (SM), M-mode, Rust (§4, §6) | `crates/sm` + `platform/qemu-virt` (Rust `no_std`), linked at `0x8001e000` and embedded into OpenSBI as section `.sm` |
| Untrusted application (UAPP) that creates an enclave (§4.2.2) | `crates/client` (Linux program) |
| Enclave Runtime (ERT) (§4) | `runtime/` + `crates/rt` → `runtime.bin` (`fw-rt.bin`) |
| Enclave Application (EAPP), "unmodified original ELF" (§4) | any static RISC-V ELF, e.g. `tests/enclave/hello.c` |
| Enclave Manager (EM), one per enclave, plus EM #0 for the normal world (§4.2.1) | no separate EM component; the runtime of a **Linux Service Enclave (LSE)** is shared by every **Linux User Enclave (LUE)** |
| Host memory for enclaves from the OS allocator (`GFP_HIGHUSER`, ≤ 2^MAX_ORDER pages per block) (§7.2.1) | `linux/modules/tee_mod` (`/dev/teectl`): `alloc_pages(GFP_HIGHUSER, order ≤ MAX_ORDER)` + `remap_pfn_range` |
| Physical Memory Areas (PMAs) with owner and permission, `EVERYONE` owner (§4) | `crates/pma` (`Owner::EVERYONE = 0`, `Owner::HOST = 1`) |

---

## 2. Paper vs. public implementation vs. this reproduction

### 2.1 Mechanisms that are present and were exercised

| Paper claim | Public code | Reproduced here |
|---|---|---|
| **Non-intrusive SM** (§4.3, §6). OpenSBI needs only "3 lines of source code and 13 lines of build script changes". | `platform/qemu-virt/qemu.patch`, 17 non-blank added lines: 3 C lines in `sbi_hart.c` (`extern sm_init`; call `sm_init(next_addr, arg1)` instead of `mret`; `__builtin_unreachable()`), 13 build-system lines (`fw_base.S` `.incbin` of `sm.bin`, `fw_base.ldS` `.sm` section, `objects.mk` `SM_PATH`), and 1 extra debug `sbi_printf` in `sbi_hsm.c`. | ✅ The patch applies unchanged to the pinned OpenSBI. `sm_init` lands at `SM_TEXT_START`, and all 4 harts enter the SM. Step 5, G05 |
| **Trap proxy** (§4.3.1): `mtvec` points to the SM, which forwards traps to the firmware's handler. | `crates/trap_proxy`; `init.rs` calls `TrapHandler::init_redirect(sbi_handler)`. | ✅ implicitly. Linux boots and uses SBI v2.0 (TIME, IPI, RFENCE, HSM, SRST, DBCN) through the proxy. Step 7, G07 |
| **DPMP** (§4.1): PMP faults are handled in the SM, which installs PMP entries from the PMA table (NAPOT, merged into TOR when possible). | `sm.rs` `handle_pmp_fault()` handles Load/Store/Instruction access faults, computes the required PMAs (`pmas_on_paddr`, `pmas_req_vaddr`) and rewrites PMP (`update_pmp_by_pmas`, `calc_napot_area`, TOR flag). | ✅ in use: enclaves backed by non-contiguous 4 MiB blocks run correctly; the SM reports `pmp fault num` per enclave. The replacement and merge policy itself was not instrumented. Steps 10–11, G09–G10 |
| **PMA memory model** (§4): every physical range has an owner and permissions; anything owned by `EVERYONE` is accessible to all entities. | `crates/pma`; `init_pma()` marks the OpenSBI region, the SM heap and the PMA table with `PmaProp::empty()`, i.e. owner `EVERYONE` with **no** permissions. | ⚠️ This interaction caused the hang in §6.1. Patch 0003 publishes those ranges as reserved memory. Step 12, G10–G11 |
| **Enclave memory from the host OS, no pre-reserved region** (§7.2.1, §7.3). | `teectl` allocates through the Linux page allocator; `dmesg` shows `[teectl] 5120 pages needed` for a 20 MiB enclave. | ✅ Step 9, G09 |
| **Edge calls / syscall proxy** through shared memory; proxied syscalls are not protected (§4.2.4). | The runtime proxies file I/O into a 16 KiB shared area; `client` executes it (`proxy_system_call`). | ✅ `write(2)` from the enclave appears on the host terminal; a micro-benchmark measures its cost. Steps 10–11 |
| **Lazy page allocation** in the runtime (§6). | `crates/rt/src/trap.rs` handles load, store and instruction page faults. | Not measured separately. |
| **Implementation language: Rust** (§6). | SM, runtime and client are Rust. | ✅ Built with the pinned `nightly-2024-11-27`. |

### 2.2 Paper features that differ from or are missing in the public code

| Paper | Public code (`05664a2`) |
|---|---|
| **Decoupled enclave management** with a user-supplied EM in every enclave and an ecall API of `sm_new_enc`, `sm_init_enc`, `sm_regi_em`, `sm_move_mem`, `sm_check_mem`, `sm_resume_enc`, `sm_pause_enc`, `sm_rm_enc`, `sm_fini_enc`, `sm_fini_dpmp` (§4.2, Table 1). | Different API (`crates/sbi/src/ecall.rs`): `SbiSMCreateEnclave` (type User / Driver / Service), `Destroy`, `Run`, `Resume`, `Stop`, `Exit`, `Channel*`, `Copy*`, `CallPlugin`, … Enclave types are LSE / LUE / LDE. A LUE borrows the runtime and trampoline of the first LSE (`get_lse(0)`), and there is no EM. |
| **Frontend–backend DPMP for virtual memory** (§4.1.3, Fig. 4): the EM walks the page tables and the SM only validates (`sm_fini_dpmp`). | The SM walks the enclave's Sv39/Sv48 page tables itself (`pmas_req_vaddr` in `sm.rs`). |
| **Secure trap proxy** with ePMP, SallyPort/BaiLey trampolines and boot-time firmware binary check (§4.3.2). | No ePMP / Smepmp code, and no SP/BL trampolines. |
| **Attestation**: the SM measures the EM, and the EM measures the rest (§4.2.2). | `measure_data()` computes an MD5 over the LUE binary. No attestation flow. |
| (not in the paper) **Linux Driver Enclave** | `client --lde` sends enclave type 2, but `create_enclave()` accepts only 1 and 3 and otherwise calls `panic!` (G10 §1b). |

The public code was committed in May 2025, while the paper was published in
December 2026. It therefore appears to implement an earlier design iteration
than the one described in the paper. This reproduction exercises the public
code as it is.

### 2.3 Evaluation: paper vs. this reproduction

| | Paper (§7) | This reproduction |
|---|---|---|
| Platforms | VisionFive 2 (JH7110, 8 GB, **8 PMP**, Linux 6.6.20), BPI-F3 (SpacemiT K1, 4 GB, **32 PMP**, Linux 6.6.25); QEMU `virt` for the compatibility check; also ported to RustSBI | QEMU 8.2 `virt` only (TCG, **16 PMP**, 4 GiB, 4 harts), Linux 7.0.0-31, OpenSBI v1.5 |
| Trap-proxy overhead | Boot: normal proxy no noticeable slowdown, secure proxy +43 %; ~200 instructions per proxied call | Not measured (TCG timing is not representative) |
| Enclave operation cost (Table 4) | e.g. SM new enclave 20K cycles, stop/resume 6K, SM rm 37K, DPMP 5K–8K | Not measurable in cycles on TCG. Wall-clock equivalents are in §4 (end-to-end empty enclave 129.6 ms vs. 27.7 ms native) |
| rv8, SQLite3, Llama2.c, FSCQ, darkhttpd | Overheads −0.5…1.6 % (rv8), 1.12…4.25 % (SQLite3), 0.23…1.22 % (Llama2.c); FSCQ write avg 12.9 %, read avg 23.6 %; darkhttpd ~3× lower throughput | **Not reproduced.** The workloads and harness are not in the public repository: the `tests` workspace member referenced by `Cargo.toml` is missing (patch 0001). |
| Scalability | Up to 2048 concurrent enclaves (rv8-sha512); a 32 GB enclave on QEMU | 2 / 4 / 8 concurrent enclaves, all correct; enclave size 20 MiB |
| Memory pressure | stress-ng 25/50/75 % has little effect on Lattice | Filling 85 % of RAM **hangs Linux** with the unpatched SM, because SM-private pages are not reserved (§6.1). Fixed by patch 0003. |
| TCB (Table 2) | 27K LoC incl. OpenSBI; 4.5K with ePMP | Not measured |

---

## 3. Pinned environment

| Component | Version |
|---|---|
| Host | Ubuntu 24.04.5 LTS, x86-64 |
| QEMU | 8.2.2 (Ubuntu package), machine `virt`, TCG |
| Cross toolchain | `riscv64-linux-gnu-gcc` 13.3.0, binutils 2.42 |
| Rust | `nightly-2024-11-27` (rustc 1.85.0-nightly `dff3e7ccd`), from upstream `rust-toolchain.toml` |
| Lattice | `05664a26af63e0898828a37b4387efc188388dbf` (2025-05-26) |
| OpenSBI | `ef4520b1c63fc2770b10d952a800f9734f861b0a` (v1.5-51, pinned by upstream `firmware.mk`) |
| U-Boot | `v2024.10` (`f919c3a8`); not specified upstream |
| Guest | Ubuntu 24.04.5 preinstalled server riscv64, kernel 7.0.0-31-generic |

---

## 4. Step-by-step build and run

Run the commands in order. `REPRO` is the root of this repository;
`sources/` and `work/` are created inside it and are git-ignored. The
*Paper* note under each step says which part of the paper the step
corresponds to.

### Step 0 — Host packages and the pinned Rust toolchain

*Paper:* §6 (implementation in Rust). Upstream pins `nightly-2024-11-27`
with `riscv64imac-unknown-none-elf` (SM, runtime) and
`riscv64gc-unknown-linux-gnu` (client).

```bash
sudo apt update
sudo apt install -y build-essential git curl wget xz-utils python3 bc bison flex \
  device-tree-compiler libssl-dev libgnutls28-dev python3-dev python3-setuptools swig \
  gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu libc6-dev-riscv64-cross \
  qemu-system-misc qemu-utils ipxe-qemu cloud-image-utils
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
. "$HOME/.cargo/env"
rustup toolchain install nightly-2024-11-27 --profile minimal \
  -c rust-src,rustfmt,clippy,llvm-tools-preview \
  -t riscv64imac-unknown-none-elf,riscv64gc-unknown-linux-gnu
```

`ipxe-qemu` provides `efi-virtio.rom`. Without it, QEMU refuses to create the
`virtio-net-pci` device that the upstream `Makefile` uses.

### Step 1 — Fetch and pin the sources

```bash
git clone https://github.com/junlinh12/lattice-enclave-qemu-reproduction.git
cd lattice-enclave-qemu-reproduction && export REPRO=$PWD
mkdir -p sources work
git clone https://github.com/LatticeEnclave/Lattice.git sources/Lattice
git -C sources/Lattice checkout 05664a26af63e0898828a37b4387efc188388dbf
git clone https://github.com/riscv-software-src/opensbi.git sources/opensbi
git -C sources/opensbi checkout ef4520b1c63fc2770b10d952a800f9734f861b0a
git clone --depth 1 --branch v2024.10 https://github.com/u-boot/u-boot.git sources/u-boot
```

### Step 2 — Working copy and the three reproduction patches

The upstream tree does not build as published. These three patches are the
only source changes made by this reproduction:

| Patch | Change |
|---|---|
| 0001 | Removes the missing `tests` workspace member and excludes the unused `htee_*` crates, whose workspace dependency is undeclared. |
| 0002 | Adds a `Cargo.lock` resolved for the pinned toolchain. |
| 0003 | Reserves the SM heap and PMA table in the device tree (§6.1). |

```bash
git clone sources/Lattice work/Lattice
cd "$REPRO/work/Lattice"
git checkout -b repro/qemu-virt 05664a26af63e0898828a37b4387efc188388dbf
git -c user.name=lattice-repro -c user.email=repro@localhost am "$REPRO"/patches/lattice/*.patch
git log --oneline -4
```

### Step 3 — Toolchain prefix

Upstream Makefiles and Cargo configs call `riscv64-unknown-linux-gnu-*`,
while Ubuntu ships `riscv64-linux-gnu-*`. These project-local symlinks map
one to the other; `env.sh` does the same.

```bash
mkdir -p "$REPRO/tools/bin"
for t in gcc g++ cpp ar as ld nm objcopy objdump ranlib readelf size strip; do
  ln -sf "$(command -v riscv64-linux-gnu-$t)" "$REPRO/tools/bin/riscv64-unknown-linux-gnu-$t"
done
export PATH="$REPRO/tools/bin:$PATH" CROSS_COMPILE=riscv64-unknown-linux-gnu-
```

### Step 4 — Build the Secure Monitor

*Paper:* §4 (SM), §4.1 (DPMP), §4.3 (non-intrusive SM). The SM is a
stand-alone, position-dependent binary linked at `SM_TEXT_START`.
`PMP_COUNT=16` matches QEMU `virt`; the paper's boards have 8 and 32.

```bash
cd "$REPRO/work/Lattice"
rustc -V                               # 1.85.0-nightly (dff3e7ccd 2024-11-26)
cargo fetch --locked
B=$PWD/build/qemu-virt; P=$PWD/platform/qemu-virt; mkdir -p "$B"
FW="SM_TEXT_START=0x8001e000 FW_TEXT_START=0x80000000 PMP_COUNT=16"
make -f "$P/firmware.mk" build_path="$B" platform_path="$P" profile=release $FW sm
riscv64-unknown-linux-gnu-readelf -h target/riscv64imac-unknown-none-elf/release/qemu-virt | grep Entry
#   Entry point address: 0x8001e000
```

### Step 5 — OpenSBI with the embedded SM, and U-Boot

*Paper:* §4.3 and §6. This is the "non-intrusive" integration:
`qemu.patch` only includes `sm.bin` as section `.sm` and calls `sm_init`
instead of `mret` when OpenSBI hands off to S-mode.

`firmware.mk` normally clones OpenSBI from the network, never fetches
U-Boot, fails on a first build (an unguarded `rm -r`), and has no
`sm → opensbi` ordering for `-j`. Therefore OpenSBI and U-Boot come from the
pinned local sources, the directory is pre-created, and the top-level make
runs without `-j`.

```bash
git clone -q "$REPRO/sources/opensbi" "$B/opensbi"
git -C "$B/opensbi" checkout -q ef4520b1c63fc2770b10d952a800f9734f861b0a
git -C "$B/opensbi" apply "$P/qemu.patch"
mkdir -p "$B/opensbi/build/platform/generic/firmware"
git clone -q "$REPRO/sources/u-boot" "$B/u-boot"
make -C "$B/u-boot" CROSS_COMPILE=riscv64-unknown-linux-gnu- qemu-riscv64_smode_defconfig
make -C "$B/u-boot" -j"$(nproc)" CROSS_COMPILE=riscv64-unknown-linux-gnu-
make -f "$P/firmware.mk" build_path="$B" platform_path="$P" profile=release $FW firmware
```

OpenSBI places `.sm` directly after its own `.text`. Because the SM is linked
at a fixed address, check that both agree:

```bash
riscv64-unknown-linux-gnu-nm "$B/opensbi/build/platform/generic/firmware/fw_payload.elf" | grep -w sm_init
#   000000008001e000 T sm_init
```

Firmware-only smoke test (stops after 30 s). Expected output: the OpenSBI
banner, `hart 1 started`, then `U-Boot 2024.10`.

```bash
timeout 30 qemu-system-riscv64 -machine virt -nographic -m 4096M -smp 4 -nic none -bios "$B/fw_payload.bin"
```

### Step 6 — Guest root filesystem

*Paper:* §7 uses vendor Linux 6.6 on real boards. Here Ubuntu 24.04 is used,
because Lattice builds its kernel module *inside* the guest against
`/lib/modules/$(uname -r)/build`, and 24.04 does not require RVA23 (which
QEMU 8.2 cannot emulate).

```bash
mkdir -p "$REPRO/work/images" "$REPRO/work/guest" && cd "$REPRO/work/images"
U=https://cdimage.ubuntu.com/releases/noble/release
wget -q $U/SHA256SUMS $U/SHA256SUMS.gpg $U/ubuntu-24.04.5-preinstalled-server-riscv64.img.xz
gpgv --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg SHA256SUMS.gpg SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS
xz -dk -T0 -c ubuntu-24.04.5-preinstalled-server-riscv64.img.xz > rootfs.img
qemu-img resize -f raw rootfs.img 32G
ssh-keygen -q -t ed25519 -N "" -C lattice-repro-guest -f ../guest/id_ed25519
cat > ../guest/user-data <<EOF
#cloud-config
hostname: lattice-guest
users:
  - name: ubuntu
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - $(cat ../guest/id_ed25519.pub)
package_update: true
packages: [build-essential, git]
runcmd:
  - [ sh, -c, "apt-get install -y linux-headers-\$(uname -r)" ]
final_message: "LATTICE_CLOUD_INIT_DONE"
EOF
printf 'instance-id: lattice-guest-001\nlocal-hostname: lattice-guest\n' > ../guest/meta-data
cloud-localds seed.img ../guest/user-data ../guest/meta-data
```

### Step 7 — Boot Linux on the Lattice firmware

*Paper:* §4.3.1 (trap proxy). Every SBI call that Linux makes passes through
the SM's trap handler into OpenSBI. The machine configuration matches the
upstream `Makefile` `qemu` target (`virt`, 4 GiB, 4 harts, raw virtio disk,
`virtio-net-pci`), plus an SSH port forward and the cloud-init seed.

```bash
cd "$REPRO/work"
qemu-system-riscv64 -machine virt -m 4096M -smp 4 \
  -bios Lattice/build/qemu-virt/fw_payload.bin \
  -drive file=images/rootfs.img,format=raw,if=virtio \
  -drive file=images/seed.img,format=raw,if=virtio,readonly=on \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:10022-:22 -device virtio-net-pci,netdev=net0 \
  -nographic
```

In a second terminal (the first boot, including cloud-init, takes about 3 minutes):

```bash
export REPRO=/path/to/lattice-enclave-qemu-reproduction
SSH="ssh -i $REPRO/work/guest/id_ed25519 -p 10022 -o StrictHostKeyChecking=accept-new ubuntu@127.0.0.1"
$SSH 'cloud-init status --wait; uname -r; nproc; sudo dmesg | grep -E "SBI specification|smp: Brought up|reserved mem"'
#   7.0.0-31-generic / 4 / SBI specification v2.0 detected / smp: Brought up 1 node, 4 CPUs
#   OF: reserved mem: 0x0000000080080000..0x00000000800effff (448 KiB) ... mmode_resv0@80080000   <- patch 0003
```

### Step 8 — Build the runtime (ERT), the client (UAPP) and a payload (EAPP)

*Paper:* §4 (ERT/EAPP), §6 (runtime in Rust).

```bash
cd "$REPRO/work/Lattice"
make -C runtime build                              # ERT  -> runtime.bin (used as fw-rt.bin)
(cd crates/client && cargo build --release --locked)          # UAPP
(cd crates/test_launcher && cargo build --release --locked)   # parallel launcher
riscv64-unknown-linux-gnu-gcc -static -O2 -o "$REPRO/work/hello" "$REPRO/tests/enclave/hello.c"   # EAPP
S="$REPRO/work/stage/lattice"; mkdir -p "$S/tee_mod"
cp target/riscv64gc-unknown-linux-gnu/release/client target/riscv64gc-unknown-linux-gnu/release/test_launcher "$S/"
cp target/riscv64imac-unknown-none-elf/release/runtime.bin "$S/fw-rt.bin"
cp "$REPRO/work/hello" "$S/"
cp linux/modules/tee_mod/main.c linux/modules/tee_mod/Makefile "$S/tee_mod/"
sed 's#"./testcode"#"./hello"#' crates/client/example.toml > "$S/config.toml"
```

### Step 9 — Host memory provider (`teectl`) in the guest

*Paper:* §7.2.1 / §7.3. Enclave memory comes from the OS allocator
(`GFP_HIGHUSER`, at most 2^MAX_ORDER pages per block), with no pre-reserved
region.

```bash
tar -C "$S" -cf - . | $SSH 'rm -rf ~/lattice && mkdir -p ~/lattice && tar -C ~/lattice -xf -'
$SSH 'cd ~/lattice/tee_mod && make build && sudo insmod teectl.ko && ls -l /dev/teectl'
```

`teectl` has no `module_exit`, so it cannot be unloaded; load it again after every boot.

### Step 10 — Enclave lifecycle: service enclave first, then user enclave

*Paper:* §4.2.2 (lifecycle) and §4.2.4 (edge calls). In the public code,
`create_lue()` maps the runtime and trampoline of an existing **LSE** into
every new **LUE** (§2.2). Without an LSE, the SM panics
(`sm.rs:211 get_lse(0).unwrap()`) and the machine locks up (G09). The LSE
holder process must keep running, because it owns the LSE memory. Use the
long options, since `-l` is bound to both `--lse` and `--lde`.

```bash
$SSH 'cd ~/lattice && sudo sh -c "nohup ./client --lse -c config.toml > lse.out 2>&1 < /dev/null &"; sleep 5; tail -2 lse.out'
#   lse created
#   eidx: 0x2
$SSH 'cd ~/lattice && sudo ./client -c config.toml ./hello'
#   create enclave
#   lue created
#   LATTICE_ENCLAVE_HELLO: write(2) via runtime syscall proxy      <- edge call (proxied write)
#   LATTICE_ENCLAVE_SUM=499999500000
#   enclave finished
```

The SM prints to the QEMU console, for example:
`[INFO] pmp fault num: 0` … `[INFO] Cleaning enclave 3` … `[INFO] [SM] Enclave 3 cleaned`.

### Step 11 — Evaluation

*Paper:* §7.2 (micro-benchmarks, Table 4) and Fig. 10 (parallel enclaves).
Concurrent enclaves (8 enclaves on 4 harts):

```bash
$SSH 'cd ~/lattice && sudo ./test_launcher "./client -c config.toml ./hello" 8 | grep -c "enclave finished"'
#   8
```

Micro-benchmarks:

- `tests/enclave/empty.c`: enclave create, launch and teardown cost.
- `tests/enclave/bench.c`: `getpid` (served by the runtime), proxied `write(/dev/null)` (edge call), and a compute loop.

```bash
riscv64-unknown-linux-gnu-gcc -static -O2 -o "$S/empty" "$REPRO/tests/enclave/empty.c"
riscv64-unknown-linux-gnu-gcc -static -O2 -o "$S/bench" "$REPRO/tests/enclave/bench.c"
scp -i "$REPRO/work/guest/id_ed25519" -P 10022 "$S/empty" "$S/bench" ubuntu@127.0.0.1:lattice/
$SSH 'cd ~/lattice && ./bench && sudo ./client -c config.toml ./bench | grep BENCH'
$SSH 'cd ~/lattice && sudo bash -c "for i in 1 2 3 4 5; do s=\$(date +%s%N); ./client -c config.toml ./empty >/dev/null; e=\$(date +%s%N); echo \$(( (e-s)/1000000 )) ms; done"'
```

### Step 12 — Memory pressure next to the SM (patch 0003)

*Paper:* §4 (PMA model) and §7.2.2 (high system load).

```bash
riscv64-unknown-linux-gnu-gcc -static -O2 -o "$S/memfill" "$REPRO/tests/tools/memfill.c"
scp -i "$REPRO/work/guest/id_ed25519" -P 10022 "$S/memfill" ubuntu@127.0.0.1:lattice/
$SSH 'cd ~/lattice && ./memfill $(awk "/MemAvailable/ {printf \"%d\", \$2/1024*0.85}" /proc/meminfo)'
#   with 0003:    MEMFILL_OK ...
#   without 0003: the guest hangs (all harts spin on store access faults, mcause=7)
```

To see the original bug, rebuild the firmware without 0003
(`git -C "$REPRO/work/Lattice" checkout HEAD~1`, then Steps 4–5) and repeat
this step.

---

## 5. Results (QEMU TCG — only the ratios are meaningful)

| Metric (median) | Native | LUE | Ratio |
|---|---:|---:|---:|
| End-to-end run of an empty program (create + launch + teardown) | 27.7 ms | 129.6 ms | 4.7× |
| `getpid` (served inside the runtime) | 518 ns | 7.69 µs | 15× |
| `write(/dev/null)` (edge call: enclave → SM → client → Linux) | 757 ns | 298.7 µs | ≈395× |
| Compute loop, 5·10⁷ iterations | 68.4 ms | 75.9 ms | 1.11× |
| Parallel LUEs (2 / 4 / 8) | — | all correct | — |

Raw samples: `logs/G10_eval_20261028T061245Z_results.csv`.

These numbers come from a different platform (TCG emulation) than the
paper's hardware cycle counts (Table 4) and benchmarks (§7.2), so they are
not directly comparable. They agree with the paper qualitatively: compute
inside an enclave runs close to native speed, while edge calls dominate the
overhead of I/O-heavy work (§7.2.2: FSCQ, darkhttpd).

---

## 6. Upstream issues found

### 6.1 SM-private memory is not reserved, so Linux hangs (fixed by patch 0003)

- **Layout**: `platform.rs` places the SM heap (64 KiB) and the PMA table (256 KiB) directly after OpenSBI, at `0x800a0000–0x800f0000` on `virt`.
- **Protection**: `init_pma()` gives both regions the PMA property `empty()`, which means owner `EVERYONE` with no permissions.
- **Missing step**: the step that should publish these ranges to the next stage ("update the reserved memory area" in `init.rs`) is commented out. Linux therefore treats the pages as free RAM.
- **Failure**: when Linux allocates one of these pages (under memory pressure, or during shutdown), the store faults. `handle_pmp_fault()` finds owner `EVERYONE`, installs an entry with *no* permission, and resumes, so the store faults again, forever. All harts end up spinning at the same kernel PC with `mcause=7`, and nothing is printed on the console (`logs/G10_*_cpu_state.log`).
- **Fix**: patch 0003 extends OpenSBI's `/reserved-memory` node to cover the SM heap and PMA table, using the existing helper `update_reserved_mem_region_size()`. With the fix, the G10 experiment passes and graceful shutdown works (G11).

### 6.2 Other issues

1. **An LSE must exist before any LUE.** This is undocumented; otherwise the SM panics (G09).
2. **LDE is not handled by the SM** (`panic!("unknown enclave type")`).
3. **The workspace does not load as published** (patch 0001), and no `Cargo.lock` is shipped (patch 0002).
4. **`firmware.mk`**: fails on a first build, is unsafe with `-j`, and never fetches U-Boot.
5. **`teectl`**: has no `module_exit`, and `alloc_blocks()` reads an uninitialised `page` when `order == 0`.
6. **`client` CLI**: `-l` is bound to both `--lse` and `--lde`.

---

## 7. Repository layout

```
patches/lattice/  0001-0003 (the only changes to upstream)
tests/            enclave payloads (hello, empty, bench) and tools (memfill, pagemap)
scripts/          G01-G13 gate scripts: an automated version of Section 4, with checks
logs/             all gate logs (sanitized), GATE_LEDGER.md, results CSV
docs/REPORT.md    detailed reproduction report
env.sh, fw_params.env, SOURCES_PINNED.txt
```

## 8. Limitations

- QEMU TCG only: no cycle-accurate numbers, and no real-hardware PMP counts (8 or 32).
- The paper's workloads (rv8, SQLite3, Llama2.c, FSCQ, darkhttpd, 2048 enclaves) are not in the public repository, so they were not re-run.
- The public code predates the paper and lacks the EM-based API, the secure trap proxy and LDE support (§2.2).

## 9. License / attribution

The scripts, tests and documentation in this repository are original work.
The paper is published under CC BY 4.0 and is cited, not copied. Lattice,
OpenSBI and U-Boot are fetched from their upstream repositories under their
own licenses and are not redistributed here; `patches/` contains diffs
against them.
