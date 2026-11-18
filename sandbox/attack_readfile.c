#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
int main(void){
    int fd = open("/etc/passwd", O_RDONLY);      /* есть на хосте, нет в rootfs */
    if (fd < 0){ printf("BLOCKED: open /etc/passwd failed\n"); return 1; }
    char buf[64]; long n = read(fd, buf, sizeof buf); close(fd);
    if (n > 0){ printf("BREACH: /etc/passwd read (%ld bytes)\n", n); return 0; }
    printf("BLOCKED: empty read\n"); return 1;
}
