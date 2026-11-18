#!/usr/bin/env bash
# bench2.sh — исправленный замер (бенчмарк, не сворачиваемый компилятором).
# Использует уже собранные qemu-nomask и qemu-masked из bench.sh.
#
#   chmod +x bench2.sh
#   ./bench2.sh
set -euo pipefail

QDIR="$HOME/Desktop/diplom/qemu-build/qemu-10.1.0"
BUILD="$QDIR/build"
ROOTFS="$HOME/Desktop/diplom/sandbox/rootfs"
HERE="$HOME/Desktop/diplom/sandbox"
RVA="0x100000000"
CC=x86_64-linux-gnu-gcc

SYS="$(command -v qemu-x86_64 || true)"
[ -x "$SYS" ] || SYS="$(dpkg -L qemu-user qemu-user-binfmt 2>/dev/null | grep -E '/qemu-x86_64$' | head -n1)"
NOMASK="$BUILD/qemu-nomask"
MASKED="$BUILD/qemu-masked"
[ -x "$NOMASK" ] && [ -x "$MASKED" ] || { echo "нет qemu-nomask/qemu-masked — запусти сначала bench.sh"; exit 1; }

echo "== Сборка исправленного бенчмарка =="
cat > "$HERE/bench2.c" <<'EOF'
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
EOF
$CC -O2 -static "$HERE/bench2.c" -o "$ROOTFS/bench2"
echo "  готово"

run() { "$1" ${2:-} "$ROOTFS/bench2" 2>/dev/null; }

echo
echo "== Прогон (по 2 раза, берём второй — прогретый) =="
for pass in 1 2; do
  echo "-- проход $pass:"
  echo "   SYS (без -R):  $(run "$SYS")"
  echo "   NOMASK (-R):   $(run "$NOMASK" "-R $RVA")"
  echo "   MASKED (-R):   $(run "$MASKED" "-R $RVA")"
done

cat <<'EOF'

------------------------------------------------------------------------
Чистая стоимость маски = (MASKED - NOMASK) при одинаковом -R:
  - mem_ms: здесь маска должна проявиться (+1 инструкция на обращение);
  - compute_ms: должно быть почти без разницы (мало обращений к памяти).
Пришли вывод второго прохода — посчитаю проценты и оформлю таблицу 5.3.
------------------------------------------------------------------------
EOF
