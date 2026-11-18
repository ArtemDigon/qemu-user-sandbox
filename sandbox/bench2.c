#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
static double ms(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
    return t.tv_sec*1000.0 + t.tv_nsec/1e6; }

int main(void){
    /* ПАМЯТЬ: read-modify-write, зависит от номера прохода -> не сворачивается */
    size_t N = 4*1024*1024;                 /* 4М элементов (16 МБ) */
    unsigned *a = malloc(N*sizeof(unsigned));
    for (size_t i=0;i<N;i++) a[i] = (unsigned)(i*2654435761u);
    double t0=ms();
    for (int r=0;r<20;r++)
        for (size_t i=0;i<N;i++)
            a[i] = a[i]*1103515245u + (unsigned)r;   /* чтение+запись каждого */
    double t1=ms();
    unsigned long cs=0; for (size_t i=0;i<N;i++) cs+=a[i];  /* контрольная сумма */

    /* ВЫЧИСЛЕНИЯ: чисто регистровые, почти без обращений к памяти */
    uint64_t x=0x9e3779b97f4a7c15ULL;
    double t2=ms();
    for (uint64_t i=0;i<100000000ULL;i++){
        x = x*6364136223846793005ULL + 1442695040888963407ULL;
        x ^= x>>29;
    }
    double t3=ms();

    printf("mem_ms=%.0f compute_ms=%.0f cs=%lu x=%lu\n",
           t1-t0, t3-t2, cs, (unsigned long)x);
    free(a); return 0;
}
