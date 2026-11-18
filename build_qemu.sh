#!/usr/bin/env bash
# build_qemu.sh — сборка собственного QEMU из исходников (шаги 1-3 уровня 3).
#
# Собирает ТОЛЬКО x86_64-linux-user (быстро), версия зафиксирована = 10.1.0
# (совпадает с системным qemu-user, чтобы будущий патч встал без правок).
#
# Запускать ВНУТРИ aarch64-Linux ВМ. Сборка идёт заметное время.
#
#   chmod +x build_qemu.sh
#   ./build_qemu.sh
set -euo pipefail

QVER="10.1.0"
WORK="$HOME/Desktop/diplom/qemu-build"
ROOTFS="$HOME/Desktop/diplom/sandbox/rootfs"
mkdir -p "$WORK"
cd "$WORK"

echo "== 1. Зависимости сборки =="
sudo apt-get update || echo "ВНИМАНИЕ: apt-get update с ошибкой (сторонний репозиторий) — продолжаем."
sudo apt-get install -y \
  git wget xz-utils \
  build-essential ninja-build meson pkg-config \
  python3 python3-venv flex bison \
  libglib2.0-dev

echo "== 2. Исходники QEMU $QVER =="
if [ ! -f "qemu-$QVER.tar.xz" ]; then
  echo "Скачиваю qemu-$QVER.tar.xz ..."
  if ! wget -q "https://download.qemu.org/qemu-$QVER.tar.xz"; then
    echo "Тарболл недоступен, пробую git (тег v$QVER) ..."
    rm -rf "qemu-$QVER"
    git clone --depth 1 --branch "v$QVER" \
      https://gitlab.com/qemu-project/qemu.git "qemu-$QVER"
  fi
fi
if [ -f "qemu-$QVER.tar.xz" ] && [ ! -d "qemu-$QVER" ]; then
  echo "Распаковка ..."
  tar xf "qemu-$QVER.tar.xz"
fi
cd "qemu-$QVER"
echo "Версия исходников:"; cat VERSION 2>/dev/null || true

echo "== 3. Конфигурация (только x86_64 user-mode) =="
# отдельный каталог сборки build/
./configure \
  --target-list=x86_64-linux-user \
  --prefix="$WORK/install"

echo "== 4. Сборка (это долго — можно заварить чай) =="
make -j"$(nproc)"

echo "== 5. Проверка собственного QEMU =="
BIN="$WORK/qemu-$QVER/build/qemu-x86_64"
if [ ! -x "$BIN" ]; then
  # на части версий бинарник кладётся в корень build с другим именем
  BIN="$(find "$WORK/qemu-$QVER/build" -maxdepth 1 -name 'qemu-x86_64' -type f | head -n1)"
fi
echo "Бинарник: $BIN"
ls -la "$BIN"

if [ -x "$ROOTFS/hello" ]; then
  echo "Запуск гостя через СВОЙ QEMU:"
  "$BIN" "$ROOTFS/hello"
else
  echo "ВНИМАНИЕ: не найден $ROOTFS/hello — сначала прогони setup_stand.sh."
fi

cat <<EOF

========================================================================
ГОТОВО. Собственный QEMU собран:
  $BIN

Это ЧИСТЫЙ (непропатченный) QEMU. Если он напечатал привет от гостя —
сборка работает, и можно вносить патч уровня 3 (политика do_syscall).

Запомни этот путь — на следующем шаге будем патчить исходники в:
  $WORK/qemu-$QVER/linux-user/syscall.c
и пересобирать командой:  make -C "$WORK/qemu-$QVER/build" -j\$(nproc)
========================================================================
EOF
