#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>
#include <signal.h>
#include <setjmp.h>

static sigjmp_buf jb;
static void onsegv(int s){ (void)s; siglongjmp(jb, 1); }

int main(void){
    long ps = sysconf(_SC_PAGESIZE);
    unsigned char *p = mmap(0, ps, PROT_READ|PROT_WRITE,
                            MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED){ printf("SKIP: mmap failed\n"); return 2; }
    p[0] = 0x11;

    /* дикий адрес: p + 4 ГБ. С маской 0xFFFFFFFF -> снова p. */
    volatile unsigned char *wild =
        (volatile unsigned char *)((uintptr_t)p + 0x100000000ULL);

    printf("p=%p  wild=p+4GB=%p  p[0] before=0x%02x\n",
           (void*)p, (void*)wild, p[0]);

    signal(SIGSEGV, onsegv);
    if (sigsetjmp(jb, 1) == 0) {
        *wild = 0x22;                 /* дикая запись */
        if (p[0] == 0x22) {
            printf("CONTAINED: запись по p+4GB завернулась в окно (маска активна)\n");
            return 0;
        }
        printf("ESCAPED: запись ушла за окно, p[0]=0x%02x не изменился\n", p[0]);
        return 1;
    } else {
        printf("FAULT: запись по p+4GB вызвала SIGSEGV (вне окна)\n");
        return 3;
    }
}
