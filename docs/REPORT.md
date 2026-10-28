# Lattice on QEMU: Reproduction Report

Phase A-1 of the RISC-V TEE reproduction study. This report covers every
gate (G01–G11) recorded in `logs/GATE_LEDGER.md`. Each claim below cites the
gate log that holds its evidence.

## 1. Scope and method

- **Target**: LatticeEnclave/Lattice, commit `05664a2` (upstream `main`,
  2025-05-26), built for `platform/qemu-virt`.
- **Paper**: Y. Zhao, J. He, M. Xu, W. Chen, W. Qiang, D. Zou, *Lattice:
  Enabling Scalable Enclaves for Commercial RISC-V Platforms*, ACM TACO 23(4),
  Article 132, Dec 2026, doi:10.1145/3844614. README §2 compares the paper
  claim by claim with the public code. In short, the non-intrusive SM, trap
  proxy, DPMP, PMA model, host-allocated memory and edge calls are present and
  were exercised here. The EM-based enclave API, frontend–backend DPMP, secure
  trap proxy (ePMP) and the paper's benchmark harness are not in the public
  code.
- **Method**: work proceeds in numbered *gates*. Each gate is one script in
  `scripts/` with explicit PASS/WARN/FAIL checks and one log in `logs/`.
  Every 5th gate re-reads the main task statement (checkpoints at G05 and G10).
  Every run is kept, including failed runs, so the ledger shows the full
  history.
- **Sanitization**: every log is filtered when it is written. User name, host
  name, home path, IPv4, MAC and e-mail addresses are masked. Commits use
  neutral identities.

## 2. Environment (pinned)

| Component | Version / pin | Source |
|---|---|---|
| Host OS | Ubuntu 24.04.5 LTS, x86-64 (20 threads, 30 GiB) | G01 |
| QEMU | 8.2.2 (Ubuntu `1:8.2.2+ds-0ubuntu1.18`), machine `virt`, TCG | G01 |
| Cross toolchain | `riscv64-linux-gnu-gcc` 13.3.0, binutils 2.42 (shimmed as `riscv64-unknown-linux-gnu-`) | G03 |
| Rust | `nightly-2024-11-27` (rustc 1.85.0-nightly `dff3e7ccd`) from `rust-toolchain.toml` | G03 |
| Lattice | `05664a26af63e0898828a37b4387efc188388dbf` | G02 |
| OpenSBI | `ef4520b1c63fc2770b10d952a800f9734f861b0a` (v1.5-51), as pinned by `firmware.mk`, with upstream `qemu.patch` | G02/G05 |
| U-Boot | v2024.10 (`f919c3a8`); **not specified upstream**, chosen to match the OpenSBI and Rust dates | G02 |
| Guest | Ubuntu 24.04.5 preinstalled server riscv64, kernel 7.0.0-31-generic, SHA256 + GPG verified | G06 |
| VM | `-m 4096M -smp 4`, virtio-blk, virtio-net-pci (same as the upstream `Makefile` `qemu` target) | G07 |

## 3. Changes applied to upstream

| Patch | File(s) | Why |
|---|---|---|
| 0001 | `Cargo.toml` | The workspace lists a non-existent `tests` member, and the `htee_*` crates use an undeclared workspace dependency. As published, cargo cannot load the workspace. The `htee_*` crates are not used by the SM or the runtime. |
| 0002 | `Cargo.lock` | Upstream ships no lockfile. It was generated with the pinned toolchain using MSRV-aware resolution. |
| 0003 | `crates/sm/src/init.rs` | Reserves the SM heap and PMA area in the device tree (see §5.1). |

Build-harness workarounds (no source change):

- A first build of `firmware.mk` fails on an unguarded `rm -r` of a directory that does not exist yet; the directory is created in advance.
- The top-level make runs serially, because `firmware.mk` has no `sm → opensbi` dependency and is unsafe with `-j`.
- U-Boot is staged locally, because `firmware.mk` never fetches it.
- `ipxe-qemu` must be installed, because `virtio-net-pci` needs `efi-virtio.rom`.

## 4. Results

### 4.1 Build and boot (G04, G05, G07)

- SM (`qemu-virt`) builds in debug and release. `.text` and the entry point are at `SM_TEXT_START = 0x8001e000`.
- In `fw_payload.elf`, OpenSBI places the `.sm` section at `0x8001e000`, which equals `SM_TEXT_START`. The embedded bytes match `sm.bin` exactly, and the SM ends before the U-Boot payload at `0x80200000`.
- Rebuilding gives an identical `sm.bin` SHA256 (G04 vs G05).
- Boot chain: OpenSBI v1.5 → Lattice SM (`sm_init`) → U-Boot 2024.10 → GRUB (EFI) → Linux 7.0.0-31. All 4 harts start through the patched HSM path, and SBI v2.0 and HSM are detected. Login prompt after ≈60 s; first-boot cloud-init finishes in ≈160 s.

### 4.2 Enclaves (G08–G11)

| Test | Result | Log |
|---|---|---|
| `teectl.ko` builds in the guest against the 7.0 headers and loads; `/dev/teectl` appears | PASS | G08 |
| LUE without an LSE | **SM panic** at `sm.rs:211`, then hard LOCKUP / RCU stall in Linux (reproduced twice) | G09 (runs 1–2) |
| LSE (`client --lse`), then LUE `hello` ×3 | PASS: correct output; `pmp fault num: 0`; `Enclave N cleaned` | G09 v2 |
| LUE payloads `hello`, `empty`, `bench` | PASS | G10 |
| 10 sequential LUE(`empty`) runs | 10/10 | G10 |
| 2 / 4 / 8 parallel LUEs (`test_launcher`; 8 > 4 harts) | 2/2, 4/4, 8/8 correct | G10 |
| LDE | not implemented (`create_enclave` accepts only types 1 and 3) | G10 §1b |
| Memory fill to 85 % after 30+ LUEs (unpatched) | **whole-system hang** | G10 |
| Same, with patch 0003 (after 13 LUEs; LSE alive / after LSE exit) | PASS / PASS; graceful poweroff OK | G11 |

### 4.3 Micro-benchmarks (G10, QEMU TCG)

`logs/G10_eval_20261028T061245Z_results.csv` holds every sample. Medians:

| Metric | Native | LUE | Ratio | Comment |
|---|---:|---:|---:|---|
| `empty` end-to-end | 27.7 ms | 129.6 ms | 4.7× | create + launch + teardown, including `teectl` allocation |
| `getpid` | 518 ns | 7.69 µs | 15× | handled inside the enclave runtime |
| `write(/dev/null)` | 757 ns | 298.7 µs | ≈395× | proxied enclave → SM → host `client` → Linux (high variance: 223–439 µs) |
| compute loop 5·10⁷ | 68.4 ms | 75.9 ms | 1.11× | pure user-mode code |

TCG emulates privilege transitions and PMP in software, so the absolute
numbers, and very likely the size of the switch costs, differ from hardware.
These values describe the public implementation on QEMU. They are not a
check of the paper's results.

## 5. Findings

### 5.1 SM heap and PMA area are not reserved → Linux hangs (fixed by 0003)

- **Symptom**: G10, after 30+ LUEs, filling 85 % of the free RAM hung the guest (SSH dead, QEMU at 400 % CPU, nothing on the console). A shutdown hang in G09 most likely had the same cause.
- **Evidence** (`G10_*_cpu_state.log`): all 4 harts were stuck at the same kernel PC, with `mcause = 7` (store/AMO access fault). Their `mtval` values map to PA `0x800a0000` and `0x800a1000` (SM heap) and to `0x800df000`, `0x800e1000` and `0x800e2000` (SM PMA area).
- **Cause**: `platform.rs` places the heap (64 KiB) and the PMA metadata area (256 KiB) directly after the OpenSBI region (`0x800a0000–0x800f0000` on `virt`). `init_pma()` denies the host access to both. The code that should publish this to the next stage ("update the reserved memory area" in `init.rs`) is commented out. Linux therefore treats the pages as free RAM. The page allocator hands them out only under pressure, which explains why short tests pass.
- **Fix**: patch 0003 extends OpenSBI's `/reserved-memory` node that ends at the SBI region end, using the unused upstream helper `update_reserved_mem_region_size()`.
- **Verification** (G11):
  - The SM logs `reserved-memory 0x80080000..0x800a0000 extended to 0x800f0000`.
  - Linux reports `OF: reserved mem: 0x80080000..0x800effff (448 KiB)`.
  - The G10 experiment passes, with the LSE alive and after it exits, and graceful poweroff works.

### 5.2 LUE requires a registered LSE

`create_lue()` maps the runtime and trampoline of the first LSE into every
LUE (`get_lse(0).unwrap()`). Without an LSE, the SM panics in M-mode and the
system locks up. The client holding the LSE has to keep running, because it
owns the LSE's memory. Upstream does not document this order.

### 5.3 LDE not available

`client --lde` issues `create_enclave` with type 2 (Driver). The public SM
only matches User (1) and Service (3) and panics otherwise; `enter_lde` is
commented out. This was not executed.

### 5.4 Minor

- `-l` is bound to both `--lde` and `--lse` (use the long forms).
- `teectl` has no `module_exit`, so it cannot be unloaded.
- `alloc_blocks()` reads an uninitialised `page` when `order == 0`. It is not hit with the sizes used here.
- Ubuntu's cross glibc has no `rcrt1.o`, so static-PIE payloads cannot be built (environment limitation).

### 5.5 Inconclusive

After the LSE holder exits, its physical pages could not be identified:
`teectl` maps with `remap_pfn_range` (VM_PFNMAP), so `pagemap` reports them as
not present. A memory fill after the LSE exit did not hang (G11), but that
does not prove the freed LSE pages were reused.

## 6. Gate index

| Gate | Purpose |
|---|---|
| G01 | host environment check |
| G02 | fetch and pin sources |
| G03 | work clone, patches 0001/0002, toolchain shims |
| G04 | build SM |
| G05 | OpenSBI+SM+U-Boot, layout verification, smoke boot ★ checkpoint |
| G06 | guest image (verified) and cloud-init seed |
| G07 | first Linux boot |
| G08 | userland and `teectl.ko` |
| G09 | first enclave run (v1 panic → v2 LSE+LUE) |
| G10 | functional matrix and evaluation ★ checkpoint (hang found) |
| G11 | patch 0003 and re-test |
