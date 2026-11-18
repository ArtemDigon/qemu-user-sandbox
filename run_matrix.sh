#!/usr/bin/env bash
# run_matrix.sh — полная матрица "атака x конфигурация" (глава 5).
# Конфигурации:
#   голый   : системный qemu, без песочницы        (0 уровней)
#   ур.4    : sandbox + системный qemu              (уровень 4)
#   ур.2+3  : пропатченный qemu (-R), без песочницы (уровни 2 и 3)
#   всё     : sandbox + пропатченный qemu (-R)      (уровни 2,3,4)
#
# Требует: setup_stand.sh и attacks.sh уже отработали (rootfs + attack_*),
#          собран пропатченный qemu.
#
#   chmod +x run_matrix.sh
#   ./run_matrix.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$HOME/Desktop/diplom/sandbox/rootfs"
SANDBOX="$HOME/Desktop/diplom/sandbox/sandbox"
POLICY="$HOME/Desktop/diplom/sandbox/policy.conf"
PATCHED="$HOME/Desktop/diplom/qemu-build/qemu-10.1.0/build/qemu-x86_64"
RVA="0x100000000"

SYS_QEMU="$(command -v qemu-x86_64 || true)"
[ -x "$SYS_QEMU" ] || SYS_QEMU="$(dpkg -L qemu-user qemu-user-binfmt 2>/dev/null | grep -E '/qemu-x86_64$' | head -n1)"
[ -x "$SYS_QEMU" ] || { echo "нет системного qemu-x86_64"; exit 1; }
[ -x "$PATCHED" ]  || { echo "нет пропатченного qemu: $PATCHED"; exit 1; }
[ -x "$SANDBOX" ]  || { echo "нет sandbox — запусти setup_stand.sh"; exit 1; }

for a in readfile network forkbomb procmem; do
  [ -x "$ROOTFS/attack_$a" ] || { echo "нет attack_$a — запусти attacks.sh"; exit 1; }
done

echo "== Копирование пропатченного qemu в rootfs (/bin/qemu-patched) =="
copy_with_libs() {
  local bin="$1" dst="$2"
  install -D "$bin" "$ROOTFS$dst"
  if ldd "$bin" >/dev/null 2>&1; then
    ldd "$bin" | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | sort -u | \
      while read -r lib; do [ -e "$lib" ] && install -D "$lib" "$ROOTFS$lib"; done
    local ld; ld="$(readelf -l "$bin" 2>/dev/null | sed -n 's/.*interpreter: \(.*\)]/\1/p' | head -n1)"
    [ -n "$ld" ] && [ -e "$ld" ] && install -D "$ld" "$ROOTFS$ld" || true
  fi
}
copy_with_libs "$PATCHED" /bin/qemu-patched
echo "  готово"

# --- запуск одной атаки в конфигурации, печать кода возврата ---
run_goly()  { "$SYS_QEMU" "$ROOTFS/attack_$1" >/dev/null 2>&1; echo $?; }
run_ur4()   { sudo "$SANDBOX" --rootfs "$ROOTFS" --policy "$POLICY" ${2:-} \
                   -- /bin/qemu-x86_64 "/attack_$1" >/dev/null 2>&1; echo $?; }
run_patch() { "$PATCHED" -R "$RVA" "$ROOTFS/attack_$1" >/dev/null 2>&1; echo $?; }
run_all()   { sudo "$SANDBOX" --rootfs "$ROOTFS" --policy "$POLICY" ${2:-} \
                   -- /bin/qemu-patched -R "$RVA" "/attack_$1" >/dev/null 2>&1; echo $?; }
verdict()   { [ "$1" = "0" ] && echo "ПРОБИТО" || echo "БЛОК"; }

echo
echo "== Полная матрица (sudo для конфигураций с песочницей) =="
echo
printf "%-12s | %-8s | %-8s | %-8s | %-6s\n" "Атака" "голый" "ур.4" "ур.2+3" "всё"
printf -- "-------------+----------+----------+----------+-------\n"
for a in readfile network forkbomb procmem; do
  extra=""; [ "$a" = "forkbomb" ] && extra="--pids 15"
  g=$(run_goly "$a")
  u4=$(run_ur4 "$a" "$extra")
  p=$(run_patch "$a")
  al=$(run_all "$a" "$extra")
  printf "%-12s | %-8s | %-8s | %-8s | %-6s\n" \
    "$a" "$(verdict $g)" "$(verdict $u4)" "$(verdict $p)" "$(verdict $al)"
done

cat <<'EOF'

------------------------------------------------------------------------
Ожидаемая картина:
  readfile/network/forkbomb : голый=ПРОБИТО, ур.4=БЛОК, ур.2+3=ПРОБИТО, всё=БЛОК
      -> OS-атаки закрывает только уровень ядра (4)
  procmem                   : БЛОК везде (параметр ядра активен), НО
      в ур.2+3/всё блокируется патчем на ОТКРЫТИИ (уровень 3), а в
      голый/ур.4 — ядром на записи. (см. strace в журнале)

Вывод: только конфигурация "всё" закрывает ВСЕ векторы. Уровни 2+3
(пропатченный qemu) закрывают память транслятора, но не дают изоляции
ОС; уровень 4 даёт изоляцию ОС, но не защищает память транслятора.
Именно поэтому нужны все уровни вместе.
------------------------------------------------------------------------
EOF
