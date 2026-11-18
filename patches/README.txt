Патчи для QEMU 10.1.0 (user-mode, x86_64-linux-user).
Применять к чистым исходникам qemu-10.1.0 (скачиваются build_qemu.sh):
  cd qemu-10.1.0
  patch -p0 linux-user/syscall.c           < ../patches/level3_syscall.patch
  patch -p0 tcg/aarch64/tcg-target.c.inc   < ../patches/level2_tcg_mask.patch
  patch -p0 linux-user/elfload.c           < ../patches/level2_vsyscall.patch
Запуск пропатченного qemu-x86_64 с окном: -R 0x100000000
