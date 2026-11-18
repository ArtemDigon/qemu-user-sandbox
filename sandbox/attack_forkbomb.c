#include <unistd.h>
#include <sys/wait.h>
#include <stdio.h>
int main(void){
    int N = 30, ok = 0;
    for (int i = 0; i < N; i++){
        pid_t p = fork();
        if (p < 0) break;                 /* достигли лимита */
        if (p == 0){ sleep(1); _exit(0); } /* ребёнок живёт секунду */
        ok++;
    }
    while (wait(0) > 0){}
    printf("forked=%d/%d\n", ok, N);
    if (ok >= N){ printf("BREACH: reached fork cap\n"); return 0; }
    printf("BLOCKED: forks limited (%d)\n", ok); return 1;
}
