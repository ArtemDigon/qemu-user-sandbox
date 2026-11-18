#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static double ms(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
    return t.tv_sec*1000.0 + t.tv_nsec/1e6; }
int main(void){
    size_t N = 8*1024*1024;              /* 8 МБ */
    unsigned char *a = malloc(N); memset(a,1,N);
    double t0=ms(); unsigned long sum=0;
    for(int r=0;r<5;r++) for(size_t i=0;i<N;i++) sum+=a[i];   /* память: 40М обращений */
    double t1=ms();
    volatile unsigned long x=12345; double t2=ms();
    for(unsigned long i=0;i<50000000UL;i++){ x=x*1103515245UL+12345UL; x^=x>>7; }
    double t3=ms();
    printf("mem_ms=%.0f compute_ms=%.0f\n", t1-t0, t3-t2);
    free(a); return 0;
}
