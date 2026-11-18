#!/usr/bin/env bash
# patch_level2b.sh — добивка уровня 2: сделать vsyscall-страницу необязательной,
# чтобы -R reserved_va работал на x86-64 (без фатальной ошибки).
#
#   chmod +x patch_level2b.sh
#   ./patch_level2b.sh
set -euo pipefail

QDIR="$HOME/Desktop/diplom/qemu-build/qemu-10.1.0"
ELF="$QDIR/linux-user/elfload.c"
BUILD="$QDIR/build"
ROOTFS="$HOME/Desktop/diplom/sandbox/rootfs"
BIN="$BUILD/qemu-x86_64"
RVA="0x100000000"

[ -f "$ELF" ] || { echo "ОШИБКА: не найден $ELF"; exit 1; }

echo "== 1. Бэкап elfload.c (один раз) =="
[ -f "$ELF.orig" ] || cp "$ELF" "$ELF.orig"

echo "== 2. Патч init_guest_commpage (vsyscall -> необязательна) =="
python3 - "$ELF" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8', errors='surrogateescape').read()
if 'vsyscall не требуется' in s:
    print('  уже пропатчено, пропускаю'); sys.exit(0)

old = ('        error_report("Cannot allocate vsyscall page");\n'
       '        exit(EXIT_FAILURE);\n')
new = ('        /* Уровень 2 (SFI): окно меньше адреса vsyscall -- пропускаем */\n'
       '        /* (современная glibc использует vDSO, vsyscall не требуется) */\n'
       '        return true;\n')
if old not in s:
    print('ОШИБКА: не найден блок error_report/exit для замены'); sys.exit(2)
s = s.replace(old, new, 1)
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print('  пропатчено: vsyscall теперь пропускается, а не роняет QEMU')
PY

echo "== 3. Пересборка QEMU (инкрементальная) =="
( cd "$QDIR" && make -j"$(nproc)" )

echo
echo "== 4. Проверки =="
echo "-- hello С -R $RVA (ДОЛЖЕН печатать привет):"
"$BIN" -R "$RVA" "$ROOTFS/hello" || true
echo "-- procmem С -R (уровень 3 всё ещё закрывает):"
"$BIN" -R "$RVA" "$ROOTFS/attack_procmem" || true
echo "-- readfile С -R (без песочницы уровень 4 не действует — ожидаемо пробивается):"
"$BIN" -R "$RVA" "$ROOTFS/attack_readfile" || true

cat <<EOF

------------------------------------------------------------------------
Если hello С -R печатает привет — УРОВЕНЬ 2 РАБОТАЕТ:
  маска стоит на каждом обращении к памяти и прозрачна для корректного
  кода. Все четыре уровня реализованы.

Запускать пропатченный QEMU теперь нужно с:  -R $RVA
------------------------------------------------------------------------
EOF
