#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
int main(void){
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0){ printf("BLOCKED: socket failed\n"); return 1; }
    struct sockaddr_in a; memset(&a,0,sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(53);
    inet_pton(AF_INET, "8.8.8.8", &a.sin_addr);
    int r = connect(s, (struct sockaddr*)&a, sizeof a); close(s);
    if (r == 0){ printf("BREACH: connect 8.8.8.8:53 ok\n"); return 0; }
    printf("BLOCKED: connect failed\n"); return 1;
}
