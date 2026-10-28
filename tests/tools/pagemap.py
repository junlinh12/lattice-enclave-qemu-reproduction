#!/usr/bin/env python3
"""pagemap.py PID START END  - print physical addresses backing [START, END) of PID.

Part of the lattice-enclave-qemu-reproduction harness (tests/tools/).
Needs root. Reads /proc/PID/pagemap (bit63 = present, bits 0-54 = PFN).
"""
import struct
import sys

PAGE = 4096


def main() -> int:
    pid, start, end = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
    with open(f"/proc/{pid}/pagemap", "rb") as f:
        for va in range(start, end, PAGE):
            f.seek((va // PAGE) * 8)
            (entry,) = struct.unpack("<Q", f.read(8))
            present = (entry >> 63) & 1
            pfn = entry & ((1 << 55) - 1)
            phys = pfn * PAGE if present else 0
            print(f"VA {va:#x} -> PA {phys:#x} {'present' if present else 'not-present'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
