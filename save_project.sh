#!/usr/bin/env bash
# save_project.sh — сохранить ТОЛЬКО свою работу в git (без дерева QEMU).
# Генерирует патчи-диффы QEMU, создаёт .gitignore, делает первый коммит.
#
#   chmod +x save_project.sh
#   ./save_project.sh
set -uo pipefail

ROOT="$HOME/Desktop/diplom"
QDIR="$ROOT/qemu-build/qemu-10.1.0"
PATCHES="$ROOT/patches"

cd "$ROOT" || { echo "нет $ROOT"; exit 1; }

echo "== 1. Генерация патчей-диффов QEMU =="
mkdir -p "$PATCHES"
gen() {  # $1 = путь .c относительно QDIR, $2 = имя патча
  local f="$QDIR/$1"
  if [ -f "$f" ] && [ -f "$f.orig" ]; then
    diff -u "$f.orig" "$f" > "$PATCHES/$2" || true   # diff возвращает 1 при различиях
    echo "  $2  ($(wc -l < "$PATCHES/$2") строк)"
  else
    echo "  пропуск $2 (нет $f или .orig)"
  fi
}
gen "linux-user/syscall.c"              level3_syscall.patch
gen "tcg/aarch64/tcg-target.c.inc"      level2_tcg_mask.patch
gen "linux-user/elfload.c"              level2_vsyscall.patch

echo "== 2. Заметка о версии QEMU =="
cat > "$PATCHES/README.txt" <<EOF
Патчи для QEMU 10.1.0 (user-mode, x86_64-linux-user).
Применять к чистым исходникам qemu-10.1.0 (скачиваются build_qemu.sh):
  cd qemu-10.1.0
  patch -p0 linux-user/syscall.c           < ../patches/level3_syscall.patch
  patch -p0 tcg/aarch64/tcg-target.c.inc   < ../patches/level2_tcg_mask.patch
  patch -p0 linux-user/elfload.c           < ../patches/level2_vsyscall.patch
Запуск пропатченного qemu-x86_64 с окном: -R 0x100000000
EOF
echo "  patches/README.txt"

echo "== 3. .gitignore (исключаем тяжёлое и генерируемое) =="
cat > "$ROOT/.gitignore" <<'EOF'
# дерево и сборка QEMU — не храним (качается build_qemu.sh)
qemu-build/
# генерируемое окружение
sandbox/rootfs/
# скомпилированные бинарники
sandbox/sandbox
sandbox/bench
sandbox/bench2
sandbox/attack_readfile
sandbox/attack_network
sandbox/attack_forkbomb
sandbox/attack_procmem
sandbox/attack_wildwrite
*.o
*.core
core
EOF
echo "  .gitignore создан"

echo "== 4. git init + коммит =="
if [ ! -d "$ROOT/.git" ]; then git init -q; fi
git add -A
git -c user.name="$(whoami)" -c user.email="$(whoami)@local" \
    commit -q -m "Прототип ВКР: 4 уровня защиты, патчи QEMU, эксперименты" || echo "  (нечего коммитить или уже закоммичено)"

echo
echo "== Что сохранено =="
git ls-files | sed 's/^/  /'

cat <<'EOF'

------------------------------------------------------------------------
Сохранено: твой код, скрипты и патчи QEMU (компактно).
НЕ сохранено (и правильно): дерево qemu-build, rootfs, бинарники.

Чтобы воспроизвести всё с нуля на любой машине:
  1. build_qemu.sh      — скачает и соберёт чистый QEMU 10.1.0
  2. применить патчи из patches/ (команды в patches/README.txt)
  3. setup_stand.sh     — соберёт стенд и rootfs
  4. attacks.sh / run_matrix.sh / bench2.sh — эксперименты

Три файла patches/*.patch — это и есть твой вклад в QEMU для Приложения А.
------------------------------------------------------------------------
EOF
