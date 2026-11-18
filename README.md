# Защищённый запуск приложений другой архитектуры

Прототип к выпускной квалификационной работе. Метод безопасного запуска
приложений x86-64 на хосте ARM (AArch64) средствами эмуляции пользовательского
режима QEMU с многоуровневой изоляцией.

## Идея

Эмуляция пользовательского режима QEMU сама по себе не является границей
безопасности: гость и транслятор исполняются в одном процессе и одном адресном
пространстве. Метод достраивает защиту до четырёх уровней (эшелонированная
оборона):

| Уровень | Что | Где реализован |
| --- | --- | --- |
| 4 | namespaces, cgroups, seccomp, параметр ядра `proc_mem.force_override` | запускатель `sandbox.c` + ядро |
| 3 | политика гостевых вызовов (запрет `/proc/self/mem` по пути) | патч QEMU `do_guest_openat` |
| 2 | маскирование адресов гостя (SFI) — изоляция памяти от транслятора | патч QEMU `prepare_host_addr` |
| 1 | гостевое приложение | источник угрозы |

Ближайший аналог — Docker + QEMU — обеспечивает только уровень 4. Новизна метода
в уровнях 2 и 3, закрывающих векторы на целостность транслятора.

## Требования к стенду

- Хост архитектуры AArch64 под Linux (проверено: виртуальная машина Parallels на
  Apple Silicon M1, Ubuntu 25.10, ядро 6.17).
- Ядро Linux ≥ 6.12 (для параметра `proc_mem.force_override`).
- Пакеты: `build-essential libseccomp-dev qemu-user gcc-x86-64-linux-gnu
  busybox-static git ninja-build meson pkg-config python3 flex bison
  libglib2.0-dev` (ставятся скриптами).

## Структура

```
sandbox/
  sandbox.c          запускатель (уровень 4); генерируется setup_stand.sh
  setup_stand.sh     развёртывание стенда: инструменты, sandbox.c, rootfs, гость
  attacks.sh         набор атак + прогон (голый vs уровень 4)
  run_matrix.sh      полная матрица «атака × конфигурация» (4 конфигурации)
  demo_level2.sh     демонстрация сдерживания маской (wildwrite)
  bench.sh, bench2.sh замер накладных расходов маски
  policy.conf        политика уровня 3 (заглушка)
build_qemu.sh        скачивание и сборка чистого QEMU 10.1.0 (x86_64-linux-user)
patch_level3.sh      патч уровня 3 (do_guest_openat)
patch_level2.sh      патч уровня 2 (маска в prepare_host_addr)
patch_level2b.sh     патч уровня 2 (vsyscall -> необязательна, для -R)
save_project.sh      сохранение в git + генерация патчей-диффов
patches/             компактные диффы правок QEMU (Приложение А)
```

Не хранится в git (воспроизводимо): `qemu-build/` (дерево и сборка QEMU),
`sandbox/rootfs/`, скомпилированные бинарники.

## Воспроизведение с нуля

Выполнять на AArch64-Linux. Порядок важен.

1. Стенд и запускатель (уровень 4):
   ```
   cd sandbox && ./setup_stand.sh
   ```
   Проверка: `sandbox/rootfs/hello` печатает приветствие и напрямую, и через `sandbox`.

2. Первые атаки (голый QEMU vs уровень 4):
   ```
   ./attacks.sh
   ```
   Ожидаемо: readfile/network/forkbomb — ПРОБИТО/БЛОК; procmem зависит от п.3.

3. Мера ядра (уровень 4, закрывает `/proc/self/mem` на записи). В `/etc/default/grub`
   добавить `proc_mem.force_override=never` в `GRUB_CMDLINE_LINUX_DEFAULT`, затем:
   ```
   sudo update-grub && sudo reboot
   ```

4. Сборка собственного QEMU:
   ```
   cd ~/Desktop/diplom && ./build_qemu.sh
   ```

5. Патчи транслятора:
   ```
   ./patch_level3.sh     # уровень 3: /proc/self/mem
   ./patch_level2.sh     # уровень 2: маска адресов
   ./patch_level2b.sh    # уровень 2: vsyscall -> необязательна
   ```
   Пропатченный QEMU запускается с окном: `-R 0x100000000`.

6. Полная матрица безопасности:
   ```
   cd sandbox && ./run_matrix.sh
   ```

7. Демонстрация сдерживания (уровень 2) и производительность:
   ```
   cd ~/Desktop/diplom && ./demo_level2.sh && ./bench.sh && ./bench2.sh
   ```

## Ожидаемые результаты

Матрица безопасности (`run_matrix.sh`):

```
Атака      | голый   | ур.4  | ур.2+3 | всё
readfile   | ПРОБИТО | БЛОК  | ПРОБИТО| БЛОК
network    | ПРОБИТО | БЛОК  | ПРОБИТО| БЛОК
forkbomb   | ПРОБИТО | БЛОК  | ПРОБИТО| БЛОК
procmem    | БЛОК    | БЛОК  | БЛОК   | БЛОК
```
Только конфигурация «всё» закрывает все векторы.

Сдерживание (`demo_level2.sh`): запись по адресу `p+4 ГБ` заворачивается маской
обратно в `p` (CONTAINED) — гость не выходит за окно.

Производительность (`bench2.sh`): накладные расходы маски в пределах погрешности
(< 1%) — одна дополнительная инструкция на обращение амортизируется стоимостью
трансляции.

## Патчи QEMU

Три правки чистого QEMU 10.1.0, хранятся как диффы в `patches/`:

- `level3_syscall.patch` — проверка пути в `do_guest_openat` (`linux-user/syscall.c`).
- `level2_tcg_mask.patch` — маска адреса в `prepare_host_addr`
  (`tcg/aarch64/tcg-target.c.inc`).
- `level2_vsyscall.patch` — необязательная vsyscall-страница в
  `init_guest_commpage` (`linux-user/elfload.c`).

Применение описано в `patches/README.txt`.
