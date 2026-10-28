# CoVE KVM RISCV64 on QEMU：复现记录与手动命令工作版

更新日期：2026-10-05（JST）。状态：**端到端复现未完成；尚未取得补丁版 TVM 的实际执行结果。**

目标来源：[rivosinc/cove 官方 Wiki](https://github.com/rivosinc/cove/wiki/CoVE-KVM-RISCV64-on-QEMU)。本项目以该页面的可观测运行结果为验收依据。历史源码恢复、构建和排障都服务于这一目标。

这份 README 是当前工作版，已经建立日志规范、版本基线、已验证命令和最终验收点。它还不是在全新机器上验证通过的完整安装手册。历史依赖恢复、全新目录重建、Wiki 参数对齐和最终 TVM 运行仍有未完成项，见第 9 节。

## 1. 完成标准

主线：QEMU → OpenSBI / Salus → RISC-V Host Linux → Host KVM → kvmtool 的 CoVE TVM → TVM 内部 Linux 和用户态。

最终日志必须同时证明以下结果，并能区分 Host 与 TVM 的输出来源：

| 验收项 | 所需直接证据 | 当前状态 |
| --- | --- | --- |
| Salus 和 Host 启动 | 完整外层控制台、Host 内的内核身份 | 历史启动已通过 |
| Host KVM / CoVE 可用 | KVM 设备、Host 初始化消息、TSM 就绪信息 | S55、G1 已通过 |
| 实际请求 CoVE TVM | 实际执行的 kvmtool 命令含 CoVE 选项，且有对应 Host 侧证据 | 原版执行有证据；补丁版未执行 |
| TVM Linux 与 SMP | 同一次 TVM 执行中的 Guest 内核输出、两颗 CPU 启动证据 | 未通过 |
| TVM 根文件系统与用户态 | Guest 根文件系统挂载、初始化进程启动、可交互 shell | 未通过 |
| TVM 网络与中断 | 在 TVM shell 内执行 `ifconfig`、`cat /proc/interrupts` 的结果 | 未通过 |
| 可以重复执行 | 从已审查输入重新执行相同步骤，再取得相同层级结果 | 未通过 |
| 可以公开复现 | 命令、版本、补丁、脱敏日志和结果索引对应完整 | 未通过 |

Linux 第一行输出只代表进入内核。TVM instance 创建只代表生命周期的一部分。静态构建、端口监听、Host 初始化、日志采集成功，都不能单独替代上述最终结果。

本项目复现该 PoC 的功能结果，不据此声称已验证所有安全属性、远程证明或生产部署能力。TVM 长时间运行时，必须说明退出是正常结束、用户主动停止还是观测超时；不能只以退出码 0 判定启动成功。

## 2. 从本版起执行的工作规范

1. **1 Step → 1 个权威原始 `.log` → 审查 → 下一 Step。** 一个 Step 有一个明确目的和验收点。记录命令、来源和产物所需的辅助命令属于同一 Step；独立构建、传输、启动等操作分别建 Step。
2. 每次给出可逐条输入的 Linux commandline，配套说明运行位置、输入、作用、退出码和预期输出。多行续写仅用于一条命令过长的情况。
3. 不再下发实验编排 `.sh`，不使用 `bash run-*.sh`、`source` 一个编排文件、长 `bash -c` 或隐藏循环／函数来串联实验。旧日志是证据，绝不作为命令文件执行。
4. `script` 是终端记录工具；`make`、Bazel、仓库自带的配置／固件生成工具是明确列出的构建命令。它们与助手提供的实验编排脚本不同。使用仓库工具时仍记录其仓库路径、提交和用途。
5. 一个 Step 完成后，用户上传该原始日志。审查报告给出 PASS / FAIL / BLOCKED，并区分“命令执行结果”和“被验证目标的结果”。
6. 旧日志保留原字节；新的手动流程不会倒填到旧日志中，也不会把旧失败改写成成功。
7. 每个涉及源码的 Step 记录 repository-relative path、commit、符号或行范围，以及 READ / BUILD / MODIFY。只查系统状态时明确写 `SOURCE_CODE_INVOLVED=NO`；若读取 Git 元数据，另列 `REPO_METADATA_READ=YES`。
8. 不修改冻结 parent 或主 rootfs；实验使用隔离 worktree 和运行磁盘副本。失败目录保留，重试使用新的步骤标识和目录。
9. 每个排障 Step 必须影响一个主线决策。相同症状不反复扩展检查；若信息不足，说明还缺什么，以及为什么它影响下一动作。

### 对当前方式的自评

| 用户要求 | 调整前的情况 | 本版调整 | 尚待证明 |
| --- | --- | --- | --- |
| 1Step1log | 大部分 Gate 有原始日志，但一个包装脚本常包括多个目的 | 以单一验收点划分 Step；失败后不自动进入下一实验 | 后续实际操作遵守新规范 |
| 手动 commandline | 不满足：包装脚本数量多、正文转储多，难以直接理解 | 停止使用实验包装脚本；建立手动记录模板和命令目录 | 新手动命令逐步经过现场验证 |
| GitHub 安全脱敏 | 不满足：原始日志带真实本地身份和路径，尚无审查后的公开集合 | 原始证据保留；只发布独立脱敏副本；建立发布范围和检查方法 | 实际制作、逐文件复核公开日志 |
| 详细 README | 不满足：重建报告和零散脚本不能替代完整操作手册 | 创建本工作版；后续每个 PASS Step 回填实际命令与证据 | 全新目录复现和完整 TVM 结果 |

## 3. Wiki 版本、参数差异与实验边界

2026-10-05 本次核对未能直接取得 GitHub 官方页面正文。可访问的[镜像](https://github-wiki-see.page/m/rivosinc/cove/wiki/CoVE-KVM-RISCV64-on-QEMU)标注页面最后修改于 2023-09-12。镜像是核对页面内容的辅助来源，不能证明官方页面当前内容没有变化。

旧 Chat 已恢复本地 Wiki 仓库，并使用提交 `53484cd6e1753ca4f599734904a6629976559153` 的 `CoVE-KVM-RISCV64-on-QEMU.md` 作为 2023-03-07 时间锚。现有功能源码、历史参考输出和 9 月镜像不是同一版本组合。

| 项目 | 现有实验 | 9 月镜像所示 | 处理原则 |
| --- | --- | --- | --- |
| TVM 参数 | device authorization 参数；未显式选择 PCI transport | 无上述过滤参数；显式 PCI transport | 分别记录，不能静默混用 |
| 内核版本 | 当前产物为 6.2.0 系列的功能快照 | 参考 TVM 输出为 6.3.0-rc4 系列 | 不声称逐版本相同；最终解释兼容性或调整源码组合 |
| Salus 构建 | 冻结源码使用 Bazel | 参考日志含 Cargo 构建输出 | 按实际提交的构建系统运行 |
| 仓库可用性 | QEMU 使用作者 fork 的保存分支 | 页面描述原 Rivos 仓库 | 写明替代来源及证据限度 |

镜像中的 TVM 启动命令（用于目标核对，**本轮不执行**）：

```bash
./lkvm-static run -c2 --console virtio --cove-vm -p "earlycon=sbi console=hvc1" -k ./Image --virtio-transport=pci
```

现有 S56R1 / H 的命令用于验证原崩溃及一行补丁的运行效果；它是调试实验。最终须有单独的 Wiki 参数对齐验证，不能把调试命令的结果直接命名为 Wiki 完整复现。

## 4. 当前基线和证据索引

所有路径以项目根目录为起点。README 使用可移植路径，不写实际用户名或机器名。

```bash
cd "$HOME/Project/CoVE-2023-Source-Archaeology"
export COVE_ROOT="$PWD"
```

上述两行只用于设置每次命令所在目录；不是新的构建或启动步骤。

### 功能源码

| 组件 | 项目内路径 | Git commit |
| --- | --- | --- |
| QEMU | `sources/qemu-cove-2023` | `73c0352f256c92dc775f863de38c49d1bc8d8cd0` |
| Salus | `sources/salus-2023-history` | `9019fd815d4300bc3b558386389aff3ca91873e3` |
| Linux | `sources/linux-cove-2023-functional` | `80ac7e01fcc43140c8ee846fe7829d17f7f30d5e` |
| kvmtool parent | `sources/kvmtool-cove-2023-functional` | `02924a33ea56732fdce47d8a8673fb3c0752c425` |
| Buildroot | `sources/buildroot-cove-2023` | `98843c2c71d14b38ee31b32875bb93eaa6a95f70` |
| standalone DTC | `sources/dtc-cove-2023` | `72fc810c3025f07de718f5f32a290a6cd5d1f4ee` |

QEMU 来源为 `https://github.com/atishp04/qemu.git` 的历史分支。其他源码的获取、子模块恢复和独立快照选择由旧日志记录。仅凭同名分支不能证明它等同于原远端在某日的 tip。

### 产物 SHA256

| 产物 | SHA256 |
| --- | --- |
| `sources/qemu-cove-2023/build/qemu-system-riscv64` | `2a7ca2ec76a4668bcb9adc8e253a9921e92ed37e079774079b1a2b0113daa594` |
| `runtime/COVE-S36/bazel-bin/salus` | `e90dace0419b66226736dcfea8c3f8e0e7a0b90ad986ef436501efd93e5b1f8d` |
| `sources/linux-cove-2023-functional/build/arch/riscv/boot/Image` | `c0168f595132b7ba639bf30a692e58f4efae6ec4a490c94a868de8e84a3be95e` |
| parent `lkvm-static` | `fb22cbba1e3bc5bc2eee6ad8f547b58c825eaf57c676634f9438a98bdc7b7a0c` |
| 主 `rootfs.ext2` | `33ad84601683e74f43fe2c40cf61fee6409a1e38dc7fc64b8ef3ec10990a219c` |
| `runtime/COVE-S56R2E/fdt-compatibility.patch` | `621b9601748965ec8b888a961bcb197accde0be242691761480a6c81afb01736` |
| `runtime/COVE-S56R2E/lkvm-static.patched` | `4df5524ad41bf4ef9a567a42d04284886a25968734668eda9502c0c9bc952128` |

这些是历史实测身份。换构建目录或依赖版本可能改变字节，不能用此表保证任意机器构建出相同哈希。

### 关键历史记录

| Step / Gate | 结论 | 对主线的含义 |
| --- | --- | --- |
| S36、S40R1、S43R1、S45、S46R3 | 核心产物构建通过 | 有可启动输入 |
| S51R1A、S52R1 | rootfs 构建／注入的闭环审查通过 | 主 rootfs 已登记 |
| S54R1、S55 | Host 集成启动与 KVM / CoVE 验证通过 | 可以尝试 TVM |
| S56R1 | 原版实际执行，随后 buffer overflow 中止 | 未证明 TVM Linux 启动 |
| S56R2E | 一行补丁、隔离构建和静态核对通过 | 运行效果仍未知 |
| S56R2G1 | Host 恢复通过 | 只说明当时状态 |
| S56R2H | BLOCKED，SSH banner 超时，退出 255 | 无补丁传输，无 TVM 执行 |

H 的原始文件为 `COVE-S56R2H-Patched-FDT-One-TVM-20261005-150835.log`。G1 的原始文件为 `COVE-S56R2G1-Host-Recovery-20261002-222532-sk64Cd.log`。原日志在私人证据集合中保留；公开版索引应指向脱敏副本。

## 5. 手动操作的日志模板

以下是今后每个 Step 的记录方法。**它是交互式终端记录，不是执行一个命令脚本。** 每次只输入该 Step 的命令，完成后停止并上传日志。

### 5.1 在 Ubuntu 外层终端开始记录

`STEP` 必须使用当次给出的步骤名；下面的值是说明示例，不能拿来执行全部实验。

```bash
cd "$HOME/Project/CoVE-2023-Source-Archaeology"
umask 077
mkdir -p logs
STEP=COVE-M01-Example
LOG=$(mktemp "logs/${STEP}-$(date +%Y%m%d-%H%M%S)-XXXXXX.log")
printf 'RAW_LOG=%s\n' "$LOG"
SHELL=/bin/bash script -q -e -f "$LOG"
```

`mktemp` 避免覆盖历史日志。最后一行打开一个被记录的交互 Bash；`script` 记录终端输出、命令回显和退出状态，不回放任何旧日志。不启用 `--log-in` 或 `--log-io`，避免记录隐式密码输入。

### 5.2 在被记录的终端中输入当次命令

```bash
export PS1='cove$ '
set -o pipefail
set -x
date -Is
pwd
printf '%s\n' 'STEP=COVE-M01-Example' 'ACTION=READ_ONLY' 'SOURCE_CODE_INVOLVED=NO' 'REPO_METADATA_READ=NO'
```

随后输入当次 Step 的实际命令。每个关键操作之后，立即输入以下两行，不能先执行其他命令覆盖 `$?`：

```bash
CMD_RC=$?
printf 'COMMAND_EXIT_CODE=%s\n' "$CMD_RC"
```

若关键命令非零且不属于预先解释的结果，停止当前 Step，用以下命令关闭记录：

```bash
printf 'STEP_EXIT_CODE=%s\n' "$CMD_RC"
exit "$CMD_RC"
```

通过时，先完成当前 Step 的规定验证，再记录 `STEP_EXIT_CODE=0` 并 `exit 0`。采集成功不等于被测对象健康，后者由日志审查另行判定。

回到外层终端后立刻记录返回值、日志身份和上传路径：

```bash
RECORDER_RC=$?
printf 'RECORDER_EXIT_CODE=%s\n' "$RECORDER_RC"
sha256sum "$LOG"
printf 'UPLOAD_THIS_RAW_LOG=%s\n' "$LOG"
```

权威日志内部已有命令／Step 状态，`script` 结束行也记录子 shell 状态。哈希用于识别上传原件。不能仅凭最后一次 `sha256sum` 成功判定整个实验通过。

### 5.3 源码追溯示例

涉及 kvmtool FDT 时，除 Step 实际操作外记录：

```bash
git -C sources/kvmtool-cove-2023-functional rev-parse HEAD
git -C sources/kvmtool-cove-2023-functional status --short --untracked-files=no
git -C sources/kvmtool-cove-2023-functional show HEAD:riscv/fdt.c | nl -ba | sed -n '96,106p'
printf '%s\n' 'SOURCE_PATH=riscv/fdt.c' 'SOURCE_SYMBOL=generate_cpu_nodes' 'SOURCE_LINES=96-106' 'SOURCE_ACTION=READ'
```

使用相应仓库的实际路径和 commit；补丁 worktree 的读取／修改另行记录，不把 parent HEAD 当作工作树未经修改的证明。

## 6. 已验证历史步骤的命令目录

本节把旧日志中的核心操作写成可读的 commandline，供解释实现和编写最终手册。**本轮不运行，也不能整节连续执行。** 当前产物已经存在，重复配置／构建可能改变证据；未来重建必须使用经过检查的新目录。

各条命令的完整构建输出由历史日志支持。以下命令目录没有列齐所有历史依赖获取步骤，不能作为未经补全的全新机器安装方案。执行任一重建 Step 时，仍须使用第 5 节的单步记录方式。

### 6.1 QEMU 构建

来源：S40R1。涉及 QEMU `util/async.c`、`include/qemu/queue.h` 及构建系统；构建读取源码，未修补冻结 tracked source。GCC 13 兼容调整针对生成的 Meson 构建配置。

```bash
meson configure "$COVE_ROOT/sources/qemu-cove-2023/build" -Dc_args=-Wno-error=dangling-pointer
cd "$COVE_ROOT/sources/qemu-cove-2023/build"
make -j2
```

前置条件是 S39 / S40 已完成 riscv64-softmmu 配置和子模块准备。第一行与第三行分别是配置调整、构建操作，按新规范重做时各自记录 Step。该设置只降低指定警告的错误等级，不能隐藏其他构建错误。

### 6.2 Linux 配置、授权数据和 Image

来源：S42R4、S43R1。仓库为功能快照。涉及 `arch/riscv/Kconfig`、`arch/riscv/cove/`、`arch/riscv/kvm/cove.c`、`drivers/tty/hvc/hvc_riscv_sbi.c`、`tools/device-authorize/build-firmware.py` 和对应输入 JSON。源码 READ / BUILD，生成配置和固件数据。

在新的、已审查的构建环境中，基础配置操作为：

```bash
cd "$COVE_ROOT/sources/linux-cove-2023-functional"
export ARCH=riscv
export CROSS_COMPILE=riscv64-linux-gnu-
make O=./build defconfig
scripts/config --file build/.config --enable CONFIG_RISCV_COVE_HOST
scripts/config --file build/.config --enable CONFIG_RISCV_COVE_GUEST
scripts/config --file build/.config --enable CONFIG_RISCV_SBI_V01
scripts/config --file build/.config --enable CONFIG_KVM
scripts/config --file build/.config --enable CONFIG_HVC_RISCV_SBI
scripts/config --file build/.config --enable CONFIG_FW_LOADER
```

历史授权数据生成操作为独立 Step：

```bash
cd "$COVE_ROOT/sources/linux-cove-2023-functional/tools/device-authorize"
python3 build-firmware.py --input riscv-cove.json --output riscv-cove.bin
sha256sum riscv-cove.json riscv-cove.bin
```

随后登记内置固件路径；下面使用可移植变量表达同一设置：

```bash
cd "$COVE_ROOT/sources/linux-cove-2023-functional"
scripts/config --file build/.config --set-val CONFIG_EXTRA_FIRMWARE '"riscv-cove.bin"'
scripts/config --file build/.config --set-val CONFIG_EXTRA_FIRMWARE_DIR "\"$COVE_ROOT/sources/linux-cove-2023-functional/tools/device-authorize/\""
```

实际 Image 构建为独立 Step：

```bash
cd "$COVE_ROOT/sources/linux-cove-2023-functional"
export ARCH=riscv
export CROSS_COMPILE=riscv64-linux-gnu-
make O=./build -j2
```

当前功能快照含授权数据路径；最终采用 Wiki 另一参数／源码组合时必须重新审查这些配置，不能默认为可直接删除或互换。

### 6.3 DTC / libfdt 与 kvmtool

来源：S45、S46R3。交叉工具链为 `riscv64-linux-gnu-`；历史版本是 GCC 13.3.0、Binutils 2.42。DTC 的 `libfdt/` 是构建输入；隔离安装不写 Ubuntu 系统 `/usr`。

```bash
cd "$COVE_ROOT/sources/dtc-cove-2023"
export ARCH=riscv
export CROSS_COMPILE=riscv64-linux-gnu-
export CC="${CROSS_COMPILE}gcc -mabi=lp64d -march=rv64gc"
TRIPLET=$(${CROSS_COMPILE}gcc -dumpmachine)
make NO_PYTHON=1 NO_YAML=1 DESTDIR="$COVE_ROOT/artifacts/dtc-cove-2023-riscv64-root" PREFIX=/usr LIBDIR="/usr/lib/$TRIPLET" install-lib install-includes
```

kvmtool 的静态构建为另一个 Step：

```bash
cd "$COVE_ROOT/sources/kvmtool-cove-2023-functional"
export ARCH=riscv
export CROSS_COMPILE=riscv64-linux-gnu-
make lkvm-static -j2 LIBFDT_DIR="$COVE_ROOT/sources/dtc-cove-2023/libfdt"
```

仓库相对路径至少包括 `Makefile`、`riscv/fdt.c`、`riscv/kvm.c`、`riscv/aia.c`、`include/linux/kvm.h` 和 `riscv/include/kvm/kvm-config-arch.h`。最终手册须继续保留实际配置／静态链接核对；不额外执行未经登记的 strip 操作。

### 6.4 FDT 最小修补

来源：S56R2E。修改只位于隔离 worktree 的 `riscv/fdt.c`，`generate_cpu_nodes()` 第 103 行附近。parent 不改动。

```diff
-pos += snprintf(cpu_isa + pos, CPU_ISA_MAX_LEN, "_%s",
+pos += snprintf(cpu_isa + pos, CPU_ISA_MAX_LEN - pos, "_%s",
```

上面的两行是解释性 diff，**不是可以直接交给 `git apply` 的完整补丁**。完整补丁在 `runtime/COVE-S56R2E/fdt-compatibility.patch`，哈希见第 4 节。

查看已完成修补的手动命令为：

```bash
git -C "$COVE_ROOT/runtime/COVE-S56R2E/kvmtool-patched" rev-parse HEAD
git -C "$COVE_ROOT/runtime/COVE-S56R2E/kvmtool-patched" --no-pager diff -- riscv/fdt.c
sha256sum "$COVE_ROOT/runtime/COVE-S56R2E/fdt-compatibility.patch"
sha256sum "$COVE_ROOT/runtime/COVE-S56R2E/lkvm-static.patched"
```

补丁构建历史命令为：

```bash
cd "$COVE_ROOT/runtime/COVE-S56R2E/kvmtool-patched"
export ARCH=riscv
export CROSS_COMPILE=riscv64-linux-gnu-
make lkvm-static -j2 LIBFDT_DIR="$COVE_ROOT/sources/dtc-cove-2023/libfdt"
```

修补意图是让输出地址与剩余容量一致。S56R2E 已有构建与反汇编核对；H 没有执行该产物，因此运行效果没有结论。

### 6.5 Salus

来源：S36。源码追溯为 `WORKSPACE`、`BUILD`、`.bazelrc`、`bazel/workspace_status_command.sh` 和登记的依赖提交。使用 Bazel 6.0.0、RISC-V target platform 与 nightly Rust。

核心构建命令为：

```bash
cd "$COVE_ROOT/sources/salus-2023-history"
"$COVE_ROOT/dependencies/tools/bazel-6.0.0-linux-x86_64" \
  --output_user_root="$COVE_ROOT/runtime/COVE-S36/output-user-root" \
  --batch build --announce_rc \
  --repository_cache="$COVE_ROOT/runtime/COVE-S36/repository-cache" \
  --symlink_prefix="$COVE_ROOT/runtime/COVE-S36/bazel-" \
  --jobs=2 --verbose_failures \
  --platforms=@rules_rivos//platforms:riscv64-none \
  --@rules_rust//rust/toolchain/channel=nightly //:salus-all
```

历史执行另外隔离了 home、临时目录和缓存目录。上面只提取核心构建命令，**不是历史完整环境的逐字重演**。最终新目录操作必须显式登记所用目录和已恢复的规则／工具链缓存；不能复用现有证据路径来冒充新实验。

### 6.6 Buildroot 和 Host rootfs

来源：S48、S50R3B、S51R1A、S52R1。配置入口为 `configs/qemu_riscv64_virt_min_defconfig`；工具链兼容处理涉及 `package/gcc/gcc.mk` 及生成的 host-gcc-initial 构建状态。

历史配置命令：

```bash
cd "$COVE_ROOT/sources/buildroot-cove-2023"
make qemu_riscv64_virt_min_defconfig
```

既有失败构建的兼容修复操作为：

```bash
make -j2 host-gcc-initial-reconfigure HOST_GCC_COMMON_MAKE_OPTS="gcc_cv_libc_provides_ssp=yes gcc_cv_prog_makeinfo_modern=no"
```

这条命令适用于当时已生成的失败状态，不是全新 Buildroot 安装的通用第一步。全量 rootfs 的成功构建由闭环审查支持；缺少独立上传的完整 S51 大日志，最终证据包需要明确这个历史缺口。

主 rootfs 已包含 `/root/Image` 与 parent `/root/lkvm-static`。新启动使用主 rootfs 的副本；不得对主镜像重复注入补丁版产物。最终手册需以新的日志补齐手动复制、挂载／卸载和 SHA256 核对过程。

## 7. 当前断点及下一步的范围

最近已审查的 H 结果是 SSH banner 超时、退出码 255。原 QEMU 身份和源码／主 rootfs 检查通过；H 未传输补丁，也未运行 TVM。这是 BLOCKED，不是补丁运行失败。

当前未有 H-A1 返回日志。此前提供的 `run-COVE-S56R2H-A1.sh` 从本版起停止作为下一步执行接口使用；保留文件和历史记录，不删除或改写。

下一现场 Step 的目的只有一个：**判断现有 Host 是否适合承载 TVM 实验，选择继续使用还是恢复 Host。** 它将改成逐条输入的只读命令，观察 PID 身份、线程状态、两次 CPU 时间和控制台／连接状态。该 Step 不同时传输补丁或启动 TVM。

然后依据返回日志给出下一 Step。后续主线是：

| 顺序 | 单一目的 | 本轮是否下发执行 |
| --- | --- | --- |
| 下一 Step | 决定当前 Host 的使用／恢复方式 | 否；本轮先调整方法和文档 |
| 后续 | 核对并暂存补丁版产物 | 否 |
| 后续 | 实际执行一次补丁版 TVM，审查原崩溃是否消失 | 否 |
| 后续 | 核对 Wiki 目标参数与源码支持，执行目标组合 | 否 |
| 后续 | 补齐 TVM 用户态、网络、中断与重复执行证据 | 否 |
| 收尾 | 制作脱敏公开集合并完成 README | 否 |

这张表说明方向，不授权把多个实验连续执行。若某阶段需要修补，先以具体失败日志定位源码，再单独记录修改与构建。

## 8. GitHub 发布与脱敏

### 8.1 保留证据，另建公开副本

原始日志始终是本地审查的权威资料。公开日志是明确标注的脱敏派生文件。只保留公开日志会失去原始证据；直接把原件推送到公开仓库则不满足本项目发布要求。

| 文件类型 | 私人保留 | GitHub 发布原则 |
| --- | --- | --- |
| 原始 logs、完整 transcript、HAR | 是 | 不直接发布 |
| 脱敏后的逐 Step 日志 | 原件和副本均留 | 逐文件审查后发布 |
| README、公开版本清单、最小补丁 | 是 | 检查无身份／凭据后发布 |
| 私钥、askpass、认证文件、主机指纹记录 | 按需私人保留 | 不发布 |
| rootfs、运行磁盘、内存 dump | 按需私人保留 | 不纳入默认公开仓库 |
| 构建缓存、完整外部源码副本 | 按需私人保留 | 使用来源／commit 说明替代；依许可单独处理 |

脱敏范围包括真实用户名、主机名、home 绝对路径、私人邮箱、私人 IP／域名、远端凭据、token、session cookie、SSH key 和签名下载 URL。路径用一致的 `$COVE_ROOT` / `<USER_HOME>` 等标识替换，并说明真实执行时展开为本地路径。

**保留**复现所需的 commandline 结构、仓库相对路径、公开 commit、补丁、编译选项、stdout/stderr 的技术内容、退出码、版本、产物哈希和事件顺序。不为了好看而删除失败、警告或关键时间关系。IP 等值若影响网络拓扑，保留角色和对应关系，注明替换。

### 8.2 发布文件集合

| 路径 | 内容 |
| --- | --- |
| `README.md` | 手动流程、环境、验收结果、限制和证据链接 |
| `patches/` | 实际完整 diff；原提交和修改原因 |
| `evidence/public/` | 已脱敏并复核的逐 Step `.log` |
| `docs/evidence-index.md` | Step → 命令 → 结果 → 脱敏日志 → 产物哈希 |
| `docs/versions.md` | 仓库来源、commit、工具链、配置和 Wiki 版本 |
| `docs/redaction.md` | 脱敏类别、规则和核对结果；不写真实敏感值 |

以上是最终目录约定；本次只创建 README 工作版，其余文件尚未完成。

发布仓库应拒绝加入 `logs/`、`runtime/`、`sources/`、`dependencies/`、原始聊天导出、认证材料和磁盘镜像。采用明确文件清单暂存，不使用 `git add .` 将整个实验目录纳入仓库。`.gitignore` 不是秘密检查的替代品；已经跟踪的文件仍需审查。

### 8.3 发布审查的手动命令示例

在独立公开仓库中操作；这是待实施的发布检查目录，不是本轮实验步骤：

```bash
git status --short
git diff --cached --name-only
git diff --cached --stat
git --no-pager diff --cached
```

对公开候选文件做敏感模式预筛选，使用 `-l` 只显示文件名，避免把命中的秘密再次打印进日志：

```bash
rg -l -i 'BEGIN .*PRIVATE KEY|authorization:|bearer[[:space:]]|access[_-]?token|api[_-]?key|password[[:space:]]*=|cookie:|X-Amz-Signature|[?&]sig=' README.md docs patches evidence/public
rg -l '/home/[^/[:space:]]+|/Users/[^/[:space:]]+' README.md docs patches evidence/public
```

`rg` 返回 1 只说明本次模式没有匹配；不能证明不存在所有敏感信息。命中项需要区分公开教程示例与真实凭据，并逐文件人工复核。公开仓库的历史、压缩附件和候选文件列表也要核对。实际 GitHub 上传在公开文件集合完成审查后另行执行；本轮未创建或推送 GitHub 仓库。

## 9. README 完成前的缺口

- 冻结本次最终对齐的官方 Wiki 修订内容或明确标注可取得的历史版本；记录其目标输出和与当前源码的差异。
- 将旧日志里的源码获取／子模块／依赖恢复命令补齐为手动步骤，给出每个实际可取得来源与 commit。
- 完整登记工具链、Bazel / Rust / 历史规则缓存及 Host 软件依赖；不能把当前机器已经有的环境当作读者默认条件。
- 补齐全新目录的 Buildroot 构建、rootfs 注入、运行副本和 Host 启动流程，避免复用旧证据目录。
- 真正执行补丁版 TVM，并补齐 Wiki 参数对齐、两颗 CPU、用户态 shell、网络和中断结果。
- 制作公开日志副本和索引，完成脱敏核对；由逐 Step 原始日志支撑结论。
- 在独立新目录按 README 再执行一遍；每 Step 一份日志，证明手册本身能复现。

## 10. 资料来源

1. [官方任务页面](https://github.com/rivosinc/cove/wiki/CoVE-KVM-RISCV64-on-QEMU)。
2. [2023-09-12 版本内容镜像](https://github-wiki-see.page/m/rivosinc/cove/wiki/CoVE-KVM-RISCV64-on-QEMU)，本次用于目标输出和参数差异核对。
3. 本地 Wiki 历史提交 `53484cd6e1753ca4f599734904a6629976559153`，文件 `CoVE-KVM-RISCV64-on-QEMU.md`。
4. 旧 Chat 原始 TXT / HAR 和 `CoVE-Full-Context-Reconstruction-20261002.txt`：用于上下文恢复；具体实验结论优先依据对应原始 `.log`。
5. S36、S40R1、S42R4、S43R1、S45、S46R3、S48、S50R3B、S51R1A、S52R1、S54R1、S55、S56R1、S56R2E 及最新 G1 / H 原始日志。

本次只编辑文档并核对已有资料，没有连接用户实验主机，也没有执行 README 中的构建、诊断或 TVM 命令。
