# Защищённый запуск приложений другой архитектуры

Прототип к ВКР. Запуск приложений x86-64 на хосте ARM (AArch64) под QEMU
user-mode с многоуровневой изоляцией.

Эмуляция пользовательского режима QEMU сама по себе не является границей
безопасности: гость и транслятор живут в одном процессе и одном адресном
пространстве. Метод добавляет четыре уровня защиты.

| Уровень | Что | Где |
| --- | --- | --- |
| 4 | namespaces, cgroups, seccomp + параметр ядра `proc_mem.force_override` | `sandbox.c` + ядро |
| 3 | запрет `/proc/self/mem` по пути | патч QEMU `do_guest_openat` |
| 2 | маскирование адресов гостя (SFI) | патч QEMU `prepare_host_addr` |
| 1 | гостевое приложение | источник угрозы |

Ближайший аналог, Docker + QEMU, даёт только уровень 4. Новизна — в уровнях 2 и 3,
которые закрывают векторы на память транслятора.

## Состав

```
sandbox.c          запускатель (уровень 4)
policy.conf        политика уровня 3 (заглушка)
attack_*.c         модельные атаки
attack_wildwrite.c демонстрация сдерживания (уровень 2)
bench.c            замер накладных расходов
patches/           патчи к QEMU 10.1.0 (уровни 2 и 3)
```

## Стенд

Хост AArch64 под Linux, ядро >= 6.12 (для `proc_mem.force_override`).
Проверено на Ubuntu 25.10 (ядро 6.17) в ВМ Parallels на Apple M1.

Зависимости:
```
sudo apt install build-essential libseccomp-dev qemu-user \
     gcc-x86-64-linux-gnu busybox-static
```

## Сборка

Запускатель:
```
gcc -O2 -o sandbox sandbox.c -lseccomp
```

QEMU с патчами (только целевой эмулятор, под GCC 15 нужен --disable-werror):
```
# в дереве qemu-10.1.0:
patch -p0 linux-user/syscall.c         < patches/level3_syscall.patch
patch -p0 tcg/aarch64/tcg-target.c.inc < patches/level2_tcg_mask.patch
patch -p0 linux-user/elfload.c         < patches/level2_vsyscall.patch
./configure --target-list=x86_64-linux-user --disable-werror
make -j
```
Пропатченный `qemu-x86_64` запускается с окном гостя: `-R 0x100000000`.

Уровень 4 на стороне ядра — параметр загрузки `proc_mem.force_override=never`
(в `GRUB_CMDLINE_LINUX_DEFAULT`, затем `update-grub` и перезагрузка).

## Проверка

Атаки собираются кросс-компилятором статически:
```
x86_64-linux-gnu-gcc -O2 -static attack_procmem.c -o attack_procmem
```

Уровень 3 (procmem закрыт на открытии файла):
```
./qemu-x86_64 -R 0x100000000 attack_procmem
# blocked: open /proc/self/mem failed
```

Уровень 2 (сдерживание записи за окно):
```
./qemu-x86_64 -R 0x100000000 attack_wildwrite
# contained: wild write wrapped into window
```

Уровень 4 (изоляция ОС) — запуск атаки через `sandbox`:
```
sudo ./sandbox --rootfs ./rootfs --policy ./policy.conf -- /bin/qemu-x86_64 /attack_readfile
```

## Патчи QEMU

- `level3_syscall.patch` — проверка пути в `do_guest_openat`.
- `level2_tcg_mask.patch` — маска адреса в `prepare_host_addr`.
- `level2_vsyscall.patch` — необязательная vsyscall-страница (нужно для `-R`).
