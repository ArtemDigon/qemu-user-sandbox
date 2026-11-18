#!/usr/bin/env bash
# attacks.sh — набор модельных атак и прогон по конфигурациям (слой 3a практики).
#
# Самодостаточный: сам создаёт attack_*.c, компилирует под x86-64 в rootfs,
# прогоняет каждую атаку через ДВЕ конфигурации и печатает таблицу:
#   - "голый"  : qemu-x86_64 без изоляции;
#   - "ур.4"    : через твой sandbox (namespaces+cgroups+pivot_root+seccomp).
#
# Требует, чтобы setup_stand.sh уже отработал (есть rootfs/ и sandbox).
# Запуск:
#   chmod +x attacks.sh
#   ./attacks.sh
set -uo pipefail   # без -e: нам нужны коды возврата атак, а не падение скрипта

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$HERE/rootfs"
SANDBOX="$HERE/sandbox"
POLICY="$HERE/policy.conf"

[ -d "$ROOTFS" ] || { echo "ОШИБКА: нет $ROOTFS — запусти сначала setup_stand.sh"; exit 1; }
[ -x "$SANDBOX" ] || { echo "ОШИБКА: нет $SANDBOX — запусти сначала setup_stand.sh"; exit 1; }

QEMU="$(command -v qemu-x86_64 || true)"
[ -z "$QEMU" ] && QEMU="$(dpkg -L qemu-user qemu-user-binfmt 2>/dev/null | grep -E '/qemu-x86_64$' | head -n1)"
[ -x "$QEMU" ] || { echo "ОШИБКА: не найден qemu-x86_64"; exit 1; }

CC=x86_64-linux-gnu-gcc

echo "== Создание и компиляция атак (x86-64, статически) =="

# 1) Чтение host-файла, которого нет в rootfs (изоляция ФС, namespaces/pivot_root)
cat > "$HERE/attack_readfile.c" <<'EOF'
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
EOF

# 2) Выход в сеть (сетевой namespace)
cat > "$HERE/attack_network.c" <<'EOF'
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
EOF

# 3) Форк-пресс (контрольные группы, pids.max)
cat > "$HERE/attack_forkbomb.c" <<'EOF'
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
EOF

# 4) Запись в свою RO-страницу через /proc/self/mem (обход W^X; мотивирует уровни 2-3)
cat > "$HERE/attack_procmem.c" <<'EOF'
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
EOF

for a in readfile network forkbomb procmem; do
    $CC -O2 -static "$HERE/attack_$a.c" -o "$ROOTFS/attack_$a" \
        && echo "  скомпилирован attack_$a" \
        || { echo "ОШИБКА компиляции attack_$a"; exit 1; }
done

# ---- прогон ----------------------------------------------------------------
run_bare() {  # $1 = имя атаки
    "$QEMU" "$ROOTFS/attack_$1" >/dev/null 2>&1; echo $?
}
run_l4() {    # $1 = имя атаки, $2 = доп. аргументы sandbox (напр. --pids 15)
    sudo "$SANDBOX" --rootfs "$ROOTFS" --policy "$POLICY" ${2:-} \
         -- "/attack_$1" >/dev/null 2>&1; echo $?
}
verdict() {   # $1 = код возврата: 0 = атака прошла (пробито), иначе заблокирована
    [ "$1" = "0" ] && echo "ПРОБИТО" || echo "БЛОК"
}

echo
echo "== Прогон атак (это запросит пароль sudo для уровня 4) =="
echo

printf "%-26s | %-10s | %-10s\n" "Атака (механизм)" "голый" "ур.4"
printf -- "---------------------------+------------+-----------\n"

# readfile — изоляция ФС (pivot_root)
b=$(run_bare readfile);  l=$(run_l4 readfile)
printf "%-26s | %-10s | %-10s\n" "readfile (ФС)" "$(verdict $b)" "$(verdict $l)"

# network — сетевой namespace
b=$(run_bare network);   l=$(run_l4 network)
printf "%-26s | %-10s | %-10s\n" "network (сеть)" "$(verdict $b)" "$(verdict $l)"

# forkbomb — cgroups; на уровне 4 жёстко ограничим pids, чтобы увидеть блок
b=$(run_bare forkbomb);  l=$(run_l4 forkbomb "--pids 15")
printf "%-26s | %-10s | %-10s\n" "forkbomb (cgroups)" "$(verdict $b)" "$(verdict $l)"

# procmem — уровни 2-3; ожидаем ПРОБИТО и там, и там (уровень 4 его не закрывает)
b=$(run_bare procmem);   l=$(run_l4 procmem)
printf "%-26s | %-10s | %-10s\n" "procmem (память)" "$(verdict $b)" "$(verdict $l)"

cat <<'NOTE'

------------------------------------------------------------------------
Как читать:
  ПРОБИТО = атака удалась (защита НЕ сработала)
  БЛОК    = атака остановлена

Ожидаемая картина для уровня 4:
  readfile / network / forkbomb : голый=ПРОБИТО, ур.4=БЛОК  (namespaces+cgroups работают)
  procmem                       : оба ПРОБИТО — уровень 4 этот вектор НЕ закрывает,
                                  его закроют уровни 2-3 (патч QEMU). Это и есть
                                  обоснование, зачем нужны внутренние уровни.

Если где-то картина иная (напр. network БЛОК и в "голом" — значит в ВМ нет
интернета; procmem БЛОК в "голом" — зависит от guest_base QEMU) — пришли вывод,
разберём, это нормальные нюансы стенда.
------------------------------------------------------------------------
NOTE
