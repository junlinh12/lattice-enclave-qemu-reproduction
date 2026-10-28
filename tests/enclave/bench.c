/* Micro-benchmark payload for the Lattice LUE (reproduction harness).
 *  getpid          : served inside the enclave runtime (no world switch to Linux)
 *  write(/dev/null): proxied enclave -> SM -> host client -> Linux -> back
 *  compute         : pure user-mode loop (should be ~native)               */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static long long now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}
int main(void) {
    const int NG = 10000, NW = 1000; const long NC = 50000000L;
    long long t0 = now();
    for (int i = 0; i < NG; i++) syscall(SYS_getpid);
    long long t1 = now();
    int fd = open("/dev/null", O_WRONLY); char c = 'x'; int werr = 0;
    long long t2 = now();
    for (int i = 0; i < NW; i++) if (write(fd, &c, 1) != 1) { werr = 1; break; }
    long long t3 = now();
    if (fd >= 0) close(fd);
    volatile unsigned long s = 0;
    long long t4 = now();
    for (long i = 0; i < NC; i++) s += i;
    long long t5 = now();
    printf("BENCH getpid n=%d total_ns=%lld per_ns=%lld\n", NG, t1 - t0, (t1 - t0) / NG);
    printf("BENCH write_devnull n=%d total_ns=%lld per_ns=%lld fd=%d err=%d\n", NW, t3 - t2, (t3 - t2) / NW, fd, werr);
    printf("BENCH compute n=%ld total_ns=%lld sum=%lu\n", NC, t5 - t4, (unsigned long)s);
    fflush(stdout);
    return 0;
}
