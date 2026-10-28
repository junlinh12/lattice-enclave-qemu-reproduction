/* Minimal enclave payload for the Lattice LUE smoke test (reproduction harness). */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    const char *msg = "LATTICE_ENCLAVE_HELLO: write(2) via runtime syscall proxy\n";
    write(1, msg, strlen(msg));
    unsigned long sum = 0;
    for (unsigned long i = 0; i < 1000000UL; i++) sum += i;
    printf("LATTICE_ENCLAVE_SUM=%lu\n", sum);   /* expected 499999500000 */
    fflush(stdout);
    return 0;
}
