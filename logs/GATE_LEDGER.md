# Gate Ledger - lattice-enclave-qemu-reproduction

Every 5th gate (G05, G10, ...) is a checkpoint: re-read ../../MAIN_TASK.md and
record whether the current work still serves the main task.

| Gate | Title | UTC time | Result | Log file | Checkpoint |
|------|-------|----------|--------|----------|------------|
| G01 | Host environment check | 20261026T123105Z | FAIL=0 WARN=3 | G01_host_env_20261026T123105Z.log | - |
| G02 | Fetch & pin sources | 20261026T124504Z | FAIL=0 WARN=3 | G02_fetch_pin_20261026T124504Z.log | - |
| G03 | Prepare build workspace | 20261026T125712Z | FAIL=0 WARN=0 | G03_prepare_workspace_20261026T125712Z.log | - |
| G04 | Build security monitor (debug+release) | 20261026T130113Z | FAIL=2 WARN=0 | G04_build_sm_20261026T130113Z.log | - |
| G04 | Build security monitor (debug+release) | 20261026T130918Z | FAIL=2 WARN=0 | G04_build_sm_20261026T130918Z.log | - |
| G04 | Build security monitor (debug+release) | 20261026T131039Z | FAIL=0 WARN=0 | G04_build_sm_20261026T131039Z.log | - |
| G05 | Build OpenSBI+SM+U-Boot, smoke test | 20261026T131039Z | FAIL=0 WARN=0 | G05_build_fw_20261026T131039Z.log | MAIN_TASK re-read |
| G06 | Prepare guest rootfs (Ubuntu 24.04.5 riscv64) | 20261028T033415Z | FAIL=0 WARN=0 | G06_guest_rootfs_20261028T033415Z.log | - |
| G07 | First Linux boot on Lattice fw (cloud-init) | 20261028T035507Z | FAIL=1 WARN=0 | G07_first_boot_20261028T035507Z.log | - |
| G07 | First Linux boot on Lattice fw (cloud-init) | 20261028T040026Z | FAIL=0 WARN=1 | G07_first_boot_20261028T040026Z.log | - |
| G08 | Build userland + teectl.ko, load in guest | 20261028T053046Z | FAIL=1 WARN=0 | G08_userland_module_20261028T053046Z.log | - |
| G09 | First enclave run (LUE hello x3, hello-pie) | 20261028T054214Z | FAIL=1 WARN=1 | G09_enclave_smoke_20261028T054214Z.log | - |
| G09 | First enclave run (LUE hello x3, hello-pie) | 20261028T055117Z | FAIL=1 WARN=1 | G09_enclave_smoke_20261028T055117Z.log | - |
| G09 | Enclave run v2 (LSE + LUE hello x3) | 20261028T055959Z | FAIL=0 WARN=0 | G09_enclave_smoke_20261028T055959Z.log | - |
| G10 | Functional matrix + evaluation (latency, concurrency, mem-reuse) | 20261028T061245Z | FAIL=1 WARN=1 | G10_eval_20261028T061245Z.log | MAIN_TASK re-read |
| G11 | Fix: reserve SM heap+PMA in DT (patch 0003) + re-test | 20261028T071845Z | FAIL=0 WARN=0 | G11_fix_20261028T071845Z.log | - |
| G12 | Sanitization audit + local commit | 20261028T072659Z | FAIL=1 WARN=0 | G12_publish_audit_20261028T072659Z.log | - |
| G12 | Sanitization audit + local commit | 20261028T073735Z | FAIL=0 WARN=0 | G12_publish_audit_20261028T073735Z.log | - |
| G13 | Push to GitHub + verify published content | 20261028T075105Z | FAIL=1 WARN=1 | G13_push_verify_20261028T075105Z.log | - |
| G13 | Push to GitHub + verify published content | 20261028T075436Z | FAIL=1 WARN=1 | G13_push_verify_20261028T075436Z.log | - |
| G13 | Push to GitHub + verify published content | 20261028T075629Z | FAIL=1 WARN=1 | G13_push_verify_20261028T075629Z.log | - |
| G13 | Push to GitHub + verify published content | 20261028T080050Z | FAIL=0 WARN=1 | G13_push_verify_20261028T080050Z.log | - |
| G13 | Push to GitHub + verify published content | 20261028T122426Z | FAIL=0 WARN=1 | G13_push_verify_20261028T122426Z.log | - |
