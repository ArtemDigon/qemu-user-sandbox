#define _GNU_SOURCE
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>
#include <stdio.h>
int main(void){
    long ps = sysconf(_SC_PAGESIZE);
    unsigned char *page = mmap(0, ps, PROT_READ,
                               MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED){ printf("BLOCKED: mmap failed\n"); return 1; }
    int fd = open("/proc/self/mem", O_RDWR);
    if (fd < 0){ printf("BLOCKED: open /proc/self/mem failed\n"); return 1; }
    unsigned char v = 0xAA;
    long n = pwrite(fd, &v, 1, (off_t)(uintptr_t)page);
    close(fd);
    if (n == 1 && page[0] == 0xAA){
        printf("BREACH: wrote to RO page via /proc/self/mem\n"); return 0;
    }
    printf("BLOCKED: write did not take (n=%ld val=0x%02x)\n", n, page[0]); return 1;
}
