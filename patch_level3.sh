#!/usr/bin/env bash
# patch_level3.sh — уровень 3 (QEMU 10.1): запрет /proc/self/mem.
# Патчит ОСНОВНОЙ помощник do_guest_openat (open/openat) и do_openat2 (openat2).
# Откатывает из .orig и накладывает чистый патч (без двойных вставок).
#
#   chmod +x patch_level3.sh
#   ./patch_level3.sh
set -euo pipefail

QDIR="$HOME/Desktop/diplom/qemu-build/qemu-10.1.0"
SYSCALL="$QDIR/linux-user/syscall.c"
BUILD="$QDIR/build"
ROOTFS="$HOME/Desktop/diplom/sandbox/rootfs"
BIN="$BUILD/qemu-x86_64"

[ -f "$SYSCALL" ] || { echo "ОШИБКА: не найден $SYSCALL"; exit 1; }

echo "== 1. Бэкап / откат к чистому исходнику =="
if [ -f "$SYSCALL.orig" ]; then
  cp "$SYSCALL.orig" "$SYSCALL"      # откат к оригиналу
  echo "  восстановлен из .orig"
else
  cp "$SYSCALL" "$SYSCALL.orig"
  echo "  создан бэкап .orig"
fi

echo "== 2. Патч do_guest_openat + do_openat2 =="
python3 - "$SYSCALL" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8', errors='surrogateescape').read()

helper = (
'/* --- Уровень 3: политика гостевых системных вызовов --- */\n'
'static int sbx_blocked_open_path(const char *p)\n'
'{\n'
'    if (!p) return 0;\n'
'    if (strcmp(p, "/proc/self/mem") == 0) return 1;\n'
'    if (strcmp(p, "/proc/thread-self/mem") == 0) return 1;\n'
'    {\n'
'        char self[64];\n'
'        int n = snprintf(self, sizeof self, "/proc/%d/mem", (int)getpid());\n'
'        if (n > 0 && (size_t)n < sizeof self && strcmp(p, self) == 0) return 1;\n'
'    }\n'
'    return 0;\n'
'}\n\n'
)

# --- якорь 1: определение do_guest_openat (основной путь open/openat) ---
ag = 'int do_guest_openat(CPUArchState *cpu_env, int dirfd, const char *pathname,'
ig = s.find(ag)
if ig == -1:
    print('ОШИБКА: не найдено определение do_guest_openat'); sys.exit(2)
gline = s.rfind('\n', 0, ig) + 1          # начало строки сигнатуры
brace_g = s.index('{', ig)                # { тела функции

# --- якорь 2: блок чтения пути в do_openat2 (путь openat2) ---
blk = ('    pathname = lock_user_string(guest_pathname);\n'
       '    if (!pathname) {\n'
       '        return -TARGET_EFAULT;\n'
       '    }\n')
iblk = s.find(blk)
if iblk == -1:
    print('ОШИБКА: не найден блок чтения пути в do_openat2'); sys.exit(2)

# проверка для do_guest_openat: pathname — чужой буфер, НЕ разблокируем здесь
check_g = (
'\n    /* Уровень 3: запрет открытия псевдофайла памяти процесса */\n'
'    if (sbx_blocked_open_path(pathname)) {\n'
'        errno = EPERM;\n'
'        return -1;\n'
'    }\n'
)
# проверка для do_openat2: pathname локальный, нужно разблокировать
check_2 = (
'    /* Уровень 3: запрет открытия псевдофайла памяти процесса */\n'
'    if (sbx_blocked_open_path(pathname)) {\n'
'        unlock_user(pathname, guest_pathname, 0);\n'
'        return -TARGET_EPERM;\n'
'    }\n'
)

# точки вставки в порядке возрастания: gline < brace_g < iblk
p_helper = gline
p_cg = brace_g + 1
p_c2 = iblk + len(blk)
assert p_helper < p_cg < p_c2, (p_helper, p_cg, p_c2)

result = (s[:p_helper] + helper + s[p_helper:p_cg] + check_g
          + s[p_cg:p_c2] + check_2 + s[p_c2:])
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(result)
print('  пропатчено: do_guest_openat (errno=EPERM) + do_openat2 (EPERM)')
PY

echo "== 3. Пересборка QEMU (инкрементальная) =="
( cd "$QDIR" && make -j"$(nproc)" )

echo
echo "== 4. Проверки =="
echo "-- procmem (должен блокироваться на ОТКРЫТИИ):"
"$BIN" "$ROOTFS/attack_procmem" || true
echo "-- strace openat (должен показать = -1 для /proc/self/mem):"
"$BIN" -strace "$ROOTFS/attack_procmem" 2>&1 | grep -iE "/proc/self/mem" || true
echo "-- регрессия (обычный файл должен открываться):"
"$BIN" "$ROOTFS/hello" || true

cat <<'EOF'

------------------------------------------------------------------------
Ожидается:
  procmem  -> "BLOCKED: open /proc/self/mem failed"
  strace   -> openat(...,"/proc/self/mem",...) = -1 errno=1 (EPERM)
  hello    -> "Privet iz x86-64 gostya..."  (не сломано)
------------------------------------------------------------------------
EOF
