#!/usr/bin/env bash
# demo_level2.sh — демонстрация сдерживания маской (уровень 2).
# Самодостаточный: создаёт attack_wildwrite.c, компилирует, запускает.
#
# Идея: гость пишет по адресу p+4ГБ. С маской 0xFFFFFFFF этот адрес
# заворачивается обратно в p (внутрь окна) -> запись попадает в СВОЮ память,
# до структур QEMU (вне окна) гость не дотягивается.
#
#   chmod +x demo_level2.sh
#   ./demo_level2.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$HOME/Desktop/diplom/sandbox/rootfs"
BIN="$HOME/Desktop/diplom/qemu-build/qemu-10.1.0/build/qemu-x86_64"
RVA="0x100000000"
CC=x86_64-linux-gnu-gcc

[ -x "$BIN" ] || { echo "ОШИБКА: нет пропатченного QEMU $BIN"; exit 1; }

echo "== Создание attack_wildwrite.c =="
cat > "$HERE/attack_wildwrite.c" <<'EOF'
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
EOF

$CC -O2 -static "$HERE/attack_wildwrite.c" -o "$ROOTFS/attack_wildwrite" \
  && echo "  скомпилирован" || { echo "ОШИБКА компиляции"; exit 1; }

echo
echo "== Запуск под ПРОПАТЧЕННЫМ QEMU (маска + -R $RVA) =="
"$BIN" -R "$RVA" "$ROOTFS/attack_wildwrite"
rc=$?
echo "код возврата: $rc"

cat <<EOF

------------------------------------------------------------------------
Ожидается: "CONTAINED: запись по p+4GB завернулась в окно".
  Это прямое доказательство уровня 2: любой адрес гостя маскируется и
  остаётся ВНУТРИ окна. Запись, которая без маски ушла бы по адресу
  p+4ГБ (за пределы окна гостя, в сторону структур QEMU), завёрнута
  обратно в собственную память гостя. До памяти транслятора гость не
  дотягивается в принципе.

Связка с procmem: /proc/self/mem закрыт уровнем 3 (патч do_guest_openat),
а прямой путь в память QEMU закрыт уровнем 2 (эта маска). Оба вектора
на память транслятора перекрыты.
------------------------------------------------------------------------
EOF
