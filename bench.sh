#!/usr/bin/env bash
# bench.sh — замер накладных расходов уровня 2 (маскирование адресов).
# Собирает два варианта QEMU и сравнивает:
#   SYS    : системный qemu (без маски, без -R) — референс
#   NOMASK : свой qemu БЕЗ маски, с -R          — чистая база
#   MASKED : свой qemu С маской, с -R           — наш метод
# NOMASK vs MASKED = чистая стоимость маски (оба с -R).
#
#   chmod +x bench.sh
#   ./bench.sh
set -euo pipefail

QDIR="$HOME/Desktop/diplom/qemu-build/qemu-10.1.0"
TCG="$QDIR/tcg/aarch64/tcg-target.c.inc"
BUILD="$QDIR/build"
ROOTFS="$HOME/Desktop/diplom/sandbox/rootfs"
HERE="$HOME/Desktop/diplom/sandbox"
RVA="0x100000000"
CC=x86_64-linux-gnu-gcc

SYS="$(command -v qemu-x86_64 || true)"
[ -x "$SYS" ] || SYS="$(dpkg -L qemu-user qemu-user-binfmt 2>/dev/null | grep -E '/qemu-x86_64$' | head -n1)"

apply_mask() {   # 1 = с маской, 0 = без
  local want="$1"
  cp "$TCG.orig" "$TCG"            # всегда начинаем с чистого
  if [ "$want" = "1" ]; then
    python3 - "$TCG" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8',errors='surrogateescape').read()
a='#define TCG_REG_TMP2 TCG_REG_X30'; i=s.find(a); eol=s.find('\n',i)+1
if 'SBX_GUEST_MASK' not in s:
    s=s[:eol]+'#define SBX_GUEST_MASK 0xFFFFFFFFull\n'+s[eol:]
old=('        if (guest_base || addr_type == TCG_TYPE_I32) {\n'
'            h->base = TCG_REG_GUEST_BASE;\n            h->index = addr_reg;\n'
'            h->index_ext = addr_type;\n        } else {\n'
'            h->base = addr_reg;\n            h->index = TCG_REG_XZR;\n'
'            h->index_ext = TCG_TYPE_I64;\n        }\n')
new=('        if (guest_base || addr_type == TCG_TYPE_I32) {\n'
'            tcg_out_logicali(s, I3404_ANDI, TCG_TYPE_I64, TCG_REG_TMP0,\n'
'                             addr_reg, SBX_GUEST_MASK);\n'
'            h->base = TCG_REG_GUEST_BASE;\n            h->index = TCG_REG_TMP0;\n'
'            h->index_ext = addr_type;\n        } else {\n'
'            tcg_out_logicali(s, I3404_ANDI, TCG_TYPE_I64, TCG_REG_TMP0,\n'
'                             addr_reg, SBX_GUEST_MASK);\n'
'            h->base = TCG_REG_TMP0;\n            h->index = TCG_REG_XZR;\n'
'            h->index_ext = TCG_TYPE_I64;\n        }\n')
assert old in s, "anchor prepare_host_addr not found"
s=s.replace(old,new,1); open(p,'w',encoding='utf-8',errors='surrogateescape').write(s)
print("  mask applied")
PY
  else
    echo "  mask removed"
  fi
  ( cd "$QDIR" && make -j"$(nproc)" >/dev/null 2>&1 )
}

echo "== Сборка бенчмарка (x86-64) =="
cat > "$HERE/bench.c" <<'EOF'
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
EOF
$CC -O2 -static "$HERE/bench.c" -o "$ROOTFS/bench"
echo "  готово"

echo "== Сборка варианта БЕЗ маски =="
apply_mask 0
cp "$BUILD/qemu-x86_64" "$BUILD/qemu-nomask"

echo "== Сборка варианта С маской (возврат рабочего состояния) =="
apply_mask 1
cp "$BUILD/qemu-x86_64" "$BUILD/qemu-masked"

NOMASK="$BUILD/qemu-nomask"
MASKED="$BUILD/qemu-masked"

# --- измерения ---
bench_run() { "$1" ${2:-} "$ROOTFS/bench" 2>/dev/null; }
startup() {  # среднее время запуска по 30 прогонам hello, в мс
  local bin="$1" opt="${2:-}" t0 t1
  t0=$(date +%s.%N)
  for i in $(seq 30); do "$bin" $opt "$ROOTFS/hello" >/dev/null 2>&1; done
  t1=$(date +%s.%N)
  awk "BEGIN{printf \"%.1f\", ($t1-$t0)*1000/30}"
}

echo
echo "== Прогон бенчмарков =="
echo "SYS (без -R):    $(bench_run "$SYS")"
R_NOMASK="$(bench_run "$NOMASK" "-R $RVA")"
R_MASKED="$(bench_run "$MASKED" "-R $RVA")"
echo "NOMASK (-R):     $R_NOMASK"
echo "MASKED (-R):     $R_MASKED"
echo
echo "Время запуска (ср. мс на hello):"
echo "  SYS:    $(startup "$SYS")"
echo "  NOMASK: $(startup "$NOMASK" "-R $RVA")"
echo "  MASKED: $(startup "$MASKED" "-R $RVA")"

cat <<'EOF'

------------------------------------------------------------------------
Чистая стоимость маски = (MASKED - NOMASK) при одинаковом -R.
Ожидание: на memory-нагрузке заметно (маска = +1 инструкция на обращение),
на compute-нагрузке почти ноль (мало обращений к памяти).
Числа подставь в таблицу 5.3 записки. Пришли вывод — помогу посчитать % и
оформить.
------------------------------------------------------------------------
EOF
