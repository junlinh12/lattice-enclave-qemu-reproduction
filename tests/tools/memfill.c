/* memfill <MB>: allocate and write <MB> MiB (64 MiB chunks) to force page reuse. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    size_t mb = argc > 1 ? strtoul(argv[1], 0, 10) : 256, done = 0, chunk = 64UL << 20;
    while (done < mb) {
        char *p = malloc(chunk);
        if (!p) { printf("MEMFILL malloc failed at %zu MB\n", done); return 1; }
        memset(p, 0xA5, chunk); done += 64;
    }
    printf("MEMFILL_OK %zu MB\n", done); fflush(stdout); return 0;
}
