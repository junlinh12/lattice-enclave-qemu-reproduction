# Source this file before building:  source env.sh
# Maps the toolchain prefix expected by Lattice (riscv64-unknown-linux-gnu-)
# onto Ubuntu's cross toolchain (riscv64-linux-gnu-) via project-local shims.
_REPRO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$_REPRO_ROOT/tools/bin"
for _t in gcc g++ cpp ar as ld nm objcopy objdump ranlib readelf size strip gdb; do
  if command -v "riscv64-linux-gnu-$_t" >/dev/null 2>&1 && [ ! -e "$_REPRO_ROOT/tools/bin/riscv64-unknown-linux-gnu-$_t" ]; then
    ln -s "$(command -v riscv64-linux-gnu-$_t)" "$_REPRO_ROOT/tools/bin/riscv64-unknown-linux-gnu-$_t"
  fi
done
case ":$PATH:" in *":$_REPRO_ROOT/tools/bin:"*) ;; *) export PATH="$_REPRO_ROOT/tools/bin:$PATH";; esac
export CROSS_COMPILE=riscv64-unknown-linux-gnu-
export REPRO_ROOT="$_REPRO_ROOT"
unset _t
