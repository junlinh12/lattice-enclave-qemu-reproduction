#!/usr/bin/env bash
# =============================================================================
# Project : lattice-enclave-qemu-reproduction
# Gate    : G03 - Prepare reproducible build workspace
#   1. work/Lattice      : local clone of sources/Lattice, branch repro/qemu-virt @ 05664a2
#   2. patch 0001        : minimal workspace fix (drop missing "tests", exclude htee_* crates)
#   3. env.sh + tools/bin: riscv64-unknown-linux-gnu-* -> riscv64-linux-gnu-* shims
#   4. patch 0002        : Cargo.lock generated with the pinned toolchain (MSRV-aware)
#   5. cargo fetch + metadata / dependency-tree / MSRV checks
# Usage   : bash scripts/G03_prepare_workspace.sh
# Writes  : work/, tools/bin/, env.sh, patches/lattice/*.patch, logs/G03_*.log,
#           logs/GATE_LEDGER.md, .gitignore ("work/", "tools/bin/")
# Safety  : sources/ is never modified. Existing work/Lattice at an unexpected
#           state -> FAIL without changes. Commits use a neutral identity
#           (no personal name/e-mail ends up in patches).
# =============================================================================
set -u

PROJ="$HOME/projects/lattice-enclave-qemu-reproduction"
SRC="$PROJ/sources/Lattice"
WORK="$PROJ/work/Lattice"
PATCHDIR="$PROJ/patches/lattice"
LOGDIR="$PROJ/logs"
GATE="G03"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/${GATE}_prepare_workspace_${TS}.log"
LEDGER="$LOGDIR/GATE_LEDGER.md"
BASE="05664a26af63e0898828a37b4387efc188388dbf"
BRANCH="repro/qemu-virt"
RUST_TC="nightly-2024-11-27"
GITID=(-c user.name="lattice-repro" -c user.email="repro@localhost" -c commit.gpgsign=false)
export GIT_COMMITTER_DATE="2025-05-26T00:00:00+00:00" GIT_AUTHOR_DATE="2025-05-26T00:00:00+00:00"  # deterministic patch headers

mkdir -p "$LOGDIR" "$PATCHDIR" "$PROJ/work"

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

# ----------------------------------------------------------------------------- env.sh (publishable, no host paths)
write_env() {
  cat > "$PROJ/env.sh" <<'EOF'
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
EOF
}

main() {
  sec "META"; echo "gate=$GATE timestamp_utc=$TS base=$BASE branch=$BRANCH"

  # --------------------------------------------------------------------------- 1. work clone
  sec "1. Work clone (sources/ stays pristine)"
  if [ -d "$WORK/.git" ]; then
    echo "work/Lattice exists -> verifying"
    if git -C "$WORK" merge-base --is-ancestor "$BASE" HEAD 2>/dev/null && [ "$(git -C "$WORK" branch --show-current)" = "$BRANCH" ]; then
      ok "existing work clone on $BRANCH based on $BASE"
    else fail "work/Lattice exists in unexpected state - not touching it"; return; fi
  else
    run "git clone -q --no-checkout '$SRC' '$WORK'" || { fail "local clone"; return; }
    run "git -C '$WORK' remote set-url origin https://github.com/LatticeEnclave/Lattice.git"
    run "git -C '$WORK' -c advice.detachedHead=false checkout -q -b '$BRANCH' '$BASE'" || { fail "checkout"; return; }
    ok "work clone created on $BRANCH @ $BASE"
  fi
  run "git -C '$WORK' log --oneline -3"

  # --------------------------------------------------------------------------- 2. patch 0001
  sec "2. Patch 0001: workspace members"
  if git -C "$WORK" log --format=%s "$BASE"..HEAD | grep -q '^repro: workspace'; then
    echo "already applied"; ok "patch 0001 present"
  else
    python3 -I - "$WORK/Cargo.toml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
assert '    "tests",\n' in s, "tests member line not found"
s = s.replace('    "tests",\n', '', 1)
ex = ["crates/htee_channel","crates/htee_client","crates/htee_console","crates/htee_device",
      "crates/htee_linkedlist","crates/htee_macro","crates/htee_mempool","crates/htee_vstack"]
block = 'exclude = [\n' + ''.join(f'    "{e}",\n' for e in ex) + ']\n'
assert 'resolver = "2"' in s
s = s.replace('resolver = "2"', block + 'resolver = "2"', 1)
open(p, 'w').write(s)
PY
    if [ $? -eq 0 ]; then
      run "git -C '$WORK' diff --stat"
      git -C "$WORK" add Cargo.toml
      git "${GITID[@]}" -C "$WORK" commit -q -F - <<'MSG'
repro: workspace - drop missing "tests" member, exclude htee_* crates

Upstream Cargo.toml lists "tests" as a workspace member, but no tests/
directory exists, so cargo cannot load the workspace at all.
The htee_* crates (an inactive variant) are matched by "crates/*" but
reference a workspace dependency (htee_device) that is not declared in
[workspace.dependencies]; they are not used by platform/qemu-virt or
runtime, so they are excluded. No source code is changed.
MSG
      ok "patch 0001 committed"
    else fail "patch 0001 could not be applied"; return; fi
  fi

  # --------------------------------------------------------------------------- 3. env
  sec "3. env.sh and toolchain shims"
  [ -f "$PROJ/env.sh" ] || write_env
  # shellcheck disable=SC1091
  source "$PROJ/env.sh"
  run "ls -l '$PROJ/tools/bin' | awk '{print \$9, \$10, \$11}'"
  run "riscv64-unknown-linux-gnu-gcc --version | head -1" && ok "shim riscv64-unknown-linux-gnu-gcc works" || fail "shim gcc"
  run "riscv64-unknown-linux-gnu-objcopy --version | head -1" && ok "shim objcopy works" || fail "shim objcopy"
  run "dpkg-query -W -f='\${Status} \${Package} \${Version}\n' libc6-dev-riscv64-cross 2>&1"
  dpkg-query -W -f='${Status}' libc6-dev-riscv64-cross 2>/dev/null | grep -q 'install ok installed' \
    && ok "libc6-dev-riscv64-cross installed (needed later for static userland tools)" \
    || warn "libc6-dev-riscv64-cross not installed (needed later at G08 for test_launcher +crt-static)"

  # --------------------------------------------------------------------------- 4. toolchain + lockfile
  sec "4. Pinned toolchain resolution inside work/Lattice"
  run "cd '$WORK' && rustup show active-toolchain"
  run "cd '$WORK' && rustc -vV"
  ( cd "$WORK" && rustup show active-toolchain 2>/dev/null | grep -q "^$RUST_TC" ) && ok "rust-toolchain.toml selects $RUST_TC" || fail "active toolchain is not $RUST_TC"

  sec "4b. Cargo.lock (MSRV-aware resolution against pinned rustc)"
  if git -C "$WORK" ls-files --error-unmatch Cargo.lock >/dev/null 2>&1; then
    echo "Cargo.lock already committed"; ok "Cargo.lock present"
  else
    if run "cd '$WORK' && CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS=fallback cargo generate-lockfile"; then
      git -C "$WORK" add Cargo.lock
      git "${GITID[@]}" -C "$WORK" commit -q -m "repro: add Cargo.lock generated with $RUST_TC" \
        -m "Upstream ships no lockfile. Generated with CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS=fallback so that dependency versions are compatible with the pinned toolchain."
      ok "Cargo.lock generated and committed"
    else fail "cargo generate-lockfile failed"; fi
  fi
  run "cd '$WORK' && grep -c '^name = ' Cargo.lock"

  # --------------------------------------------------------------------------- 5. checks
  sec "5a. cargo fetch (pre-download all crates)"
  run "cd '$WORK' && cargo fetch --locked" && ok "cargo fetch --locked" || fail "cargo fetch"

  sec "5b. cargo metadata"
  META="$(mktemp)"; META_OK=0
  if ( cd "$WORK" && cargo metadata --locked --format-version 1 > "$META" 2>/dev/null ); then
    META_OK=1
    ok "workspace loads (cargo metadata)"
    python3 -I - "$META" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ws = set(d["workspace_members"])
print("workspace members:", len(ws))
for p in sorted(d["packages"], key=lambda p: p["name"]):
    if p["id"] in ws:
        print(f"  {p['name']:<18} edition={p['edition']}")
print("third-party crates:")
for p in sorted(d["packages"], key=lambda p: p["name"]):
    if p["source"]:
        print(f"  {p['name']:<22} {p['version']:<10} rust-version={p.get('rust_version')}")
PY
  else fail "cargo metadata failed"; fi

  if [ "$META_OK" -ne 1 ]; then
    fail "5c/5d skipped because cargo metadata failed"; rm -f "$META"
  else
  sec "5c. MSRV check vs pinned rustc"
  RV=$(cd "$WORK" && rustc -V | awk '{print $2}' | sed 's/-.*//')
  echo "pinned rustc version: $RV"
  BAD=$(python3 -I - "$META" "$RV" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); rv = tuple(int(x) for x in sys.argv[2].split("."))
def v(s): return tuple(int(x) for x in (s.split(".") + ["0", "0"])[:3])
for p in d.get("packages", []):
    r = p.get("rust_version")
    if p["source"] and r and v(r) > rv:
        print(f"{p['name']} {p['version']} needs rust {r}")
PY
)
  if [ -z "$BAD" ]; then ok "no dependency requires a newer rustc than $RV"; else echo "$BAD"; warn "dependencies newer than pinned rustc (see above)"; fi
  rm -f "$META"

  sec "5d. Dependency tree of the security monitor (qemu-virt)"
  run "cd '$WORK/platform/qemu-virt' && cargo tree --locked -e normal --prefix depth | sort -u -k1,1n -k2 | head -60"
  if ( cd "$WORK/platform/qemu-virt" && cargo tree --locked -e normal 2>/dev/null | grep -q htee ); then
    fail "qemu-virt depends on an excluded htee_* crate"
  else ok "qemu-virt dependency tree has no htee_* crate"; fi
  fi

  # --------------------------------------------------------------------------- 6. export patches
  sec "6. Export reproduction patches"
  rm -f "$PATCHDIR"/0*.patch
  run "git -C '$WORK' format-patch -q --no-signature -o '$PATCHDIR' '$BASE'..HEAD && ls -1 '$PATCHDIR'"
  if grep -lE '@[A-Za-z0-9-]+\.[A-Za-z]{2,}' "$PATCHDIR"/*.patch 2>/dev/null | grep -q .; then
    warn "a patch contains an e-mail-like string - review before publishing"
  else ok "patches contain no personal e-mail"; fi
  run "git -C '$WORK' log --oneline '$BASE'..HEAD"

  sec "SUMMARY"
  printf '%s\n' "${SUMMARY[@]}"
  NF=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[FAIL\]'); NW=$(printf '%s\n' "${SUMMARY[@]}" | grep -c '^\[WARN\]')
  echo; echo "RESULT: FAIL=$NF WARN=$NW"
}

main 2>&1 | sanitize | tee "$LOG"
RES=$(grep -E '^RESULT:' "$LOG" | tail -1 | sed 's/RESULT: //')

touch "$PROJ/.gitignore"
for g in 'work/' 'tools/bin/'; do grep -qxF "$g" "$PROJ/.gitignore" || echo "$g" >> "$PROJ/.gitignore"; done
echo "| $GATE | Prepare build workspace | $TS | ${RES:-ABORTED} | $(basename "$LOG") | - |" >> "$LEDGER"
echo; echo ">>> Log written: logs/$(basename "$LOG")"; echo ">>> Please upload that log file to the chat."
