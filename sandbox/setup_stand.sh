#!/usr/bin/env bash
# setup_stand.sh — САМОДОСТАТОЧНОЕ развёртывание стенда (шаг 1 практики).
#
# Создаёт sandbox.c САМ (не нужен отдельный файл), собирает его,
# делает минимальный rootfs с busybox и qemu-x86_64, тестового гостя.
#
# Запускать ВНУТРИ aarch64-Linux ВМ (Parallels на M1), НЕ в macOS.
#
# Использование:
#   chmod +x setup_stand.sh
#   ./setup_stand.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$HERE/rootfs"

echo "== 1. Проверка архитектуры =="
arch="$(uname -m)"
if [ "$arch" != "aarch64" ]; then
  echo "ОШИБКА: хост не aarch64 (uname -m = $arch). Запусти в ARM-Linux ВМ."
  exit 1
fi
echo "ОК: aarch64. Ядро: $(uname -r)"

echo "== 2. Установка инструментов =="
sudo apt-get update || echo "ВНИМАНИЕ: apt-get update с ошибкой (сторонний репозиторий) — продолжаем."
sudo apt-get install -y \
  build-essential libseccomp-dev binutils \
  qemu-user \
  gcc-x86-64-linux-gnu \
  busybox-static
# qemu-user-static может называться qemu-user-binfmt — ставим, если есть, без фатала
sudo apt-get install -y qemu-user-static || true

echo "== 3. Создание и сборка sandbox.c =="
# ВАЖНО: sandbox.c пишется ЗДЕСЬ, перезаписывая любой старый файл.
cat > "$HERE/sandbox.c" <<'SANDBOX_EOF'
/* sandbox.c — запускатель изолированной среды (уровень 4). Автогенерация. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sched.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <seccomp.h>

struct config {
    const char *rootfs;
    const char *policy;
    char       **argv;
    long       mem_limit_mb;
    long       pids_limit;
};

#define STACK_SIZE (1024 * 1024)
static char child_stack[STACK_SIZE];

static void die(const char *msg) {
    fprintf(stderr, "sandbox: %s: %s\n", msg, strerror(errno));
    exit(1);
}

static void write_file(const char *path, const char *val) {
    int fd = open(path, O_WRONLY);
    if (fd < 0) die(path);
    if (write(fd, val, strlen(val)) < 0) die(path);
    close(fd);
}

/* Уровень 4a: cgroups v2 — лимиты ресурсов (защита от DoS). */
static void setup_cgroups(pid_t child, const struct config *c) {
    char path[256], val[64];
    mkdir("/sys/fs/cgroup/sandbox", 0755);
    snprintf(path, sizeof path, "/sys/fs/cgroup/sandbox/memory.max");
    snprintf(val, sizeof val, "%ldM", c->mem_limit_mb);
    write_file(path, val);
    snprintf(path, sizeof path, "/sys/fs/cgroup/sandbox/pids.max");
    snprintf(val, sizeof val, "%ld", c->pids_limit);
    write_file(path, val);
    snprintf(path, sizeof path, "/sys/fs/cgroup/sandbox/cgroup.procs");
    snprintf(val, sizeof val, "%d", child);
    write_file(path, val);
}

/* Уровень 4b: смена корня ФС + ограниченный /proc. */
static void setup_rootfs(const char *rootfs) {
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0) die("mount private");
    if (mount(rootfs, rootfs, NULL, MS_BIND | MS_REC, NULL) < 0) die("bind rootfs");
    if (chdir(rootfs) < 0) die("chdir rootfs");
    mkdir("proc", 0555);
    if (mount("proc", "proc", "proc", 0, NULL) < 0) die("mount proc");
    mkdir("old_root", 0777);
    if (syscall(SYS_pivot_root, ".", "old_root") < 0) die("pivot_root");
    if (chdir("/") < 0) die("chdir /");
    if (umount2("/old_root", MNT_DETACH) < 0) die("umount old_root");
    rmdir("/old_root");
}

/* Уровень 4c: внешний фильтр вызовов (seccomp). */
static void setup_seccomp(void) {
    scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ALLOW);
    if (!ctx) die("seccomp_init");
    int deny[] = {
        SCMP_SYS(ptrace), SCMP_SYS(process_vm_writev), SCMP_SYS(process_vm_readv),
        SCMP_SYS(mount), SCMP_SYS(umount2), SCMP_SYS(init_module),
        SCMP_SYS(finit_module), SCMP_SYS(delete_module), SCMP_SYS(kexec_load),
        SCMP_SYS(bpf), SCMP_SYS(perf_event_open), SCMP_SYS(userfaultfd),
        SCMP_SYS(keyctl), SCMP_SYS(add_key),
    };
    for (size_t i = 0; i < sizeof(deny)/sizeof(deny[0]); i++)
        if (seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), deny[i], 0) < 0)
            die("seccomp_rule_add");
    if (seccomp_load(ctx) < 0) die("seccomp_load");
    seccomp_release(ctx);
}

static int child_entry(void *arg) {
    const struct config *c = arg;
    if (sethostname("sandbox", 7) != 0) { /* не критично */ }
    setup_rootfs(c->rootfs);
    /* TODO: Landlock — ограничение доступа к ФС белым списком. */
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) die("no_new_privs");
    setup_seccomp();
    setenv("QEMU_SANDBOX_POLICY", c->policy, 1);
    execvp(c->argv[0], c->argv);
    die("execvp");
    return 1;
}

int main(int argc, char **argv) {
    struct config c = { NULL, NULL, NULL, 512, 128 };
    int i = 1;
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "--rootfs") && i+1 < argc) c.rootfs = argv[++i];
        else if (!strcmp(argv[i], "--policy") && i+1 < argc) c.policy = argv[++i];
        else if (!strcmp(argv[i], "--mem")   && i+1 < argc) c.mem_limit_mb = atol(argv[++i]);
        else if (!strcmp(argv[i], "--pids")  && i+1 < argc) c.pids_limit  = atol(argv[++i]);
        else if (!strcmp(argv[i], "--")) { c.argv = &argv[i+1]; break; }
        else { fprintf(stderr, "неизвестный аргумент: %s\n", argv[i]); return 2; }
    }
    if (!c.rootfs || !c.policy || !c.argv || !c.argv[0]) {
        fprintf(stderr, "usage: %s --rootfs DIR --policy FILE [--mem MB] [--pids N] -- CMD...\n", argv[0]);
        return 2;
    }
    int flags = CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWNET |
                CLONE_NEWIPC | CLONE_NEWUTS | SIGCHLD;
    pid_t pid = clone(child_entry, child_stack + STACK_SIZE, flags, &c);
    if (pid < 0) die("clone");
    setup_cgroups(pid, &c);
    int status;
    if (waitpid(pid, &status, 0) < 0) die("waitpid");
    if (WIFEXITED(status))   return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 0;
}
SANDBOX_EOF

gcc -O2 -Wall -o "$HERE/sandbox" "$HERE/sandbox.c" -lseccomp
echo "ОК: собран $HERE/sandbox"

copy_with_libs() {
  local bin="$1" dest_path="$2"
  install -D "$bin" "$ROOTFS$dest_path"
  if ldd "$bin" >/dev/null 2>&1; then
    ldd "$bin" | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^\//) print $i }' | sort -u | \
    while read -r lib; do [ -e "$lib" ] && install -D "$lib" "$ROOTFS$lib"; done
    local loader
    loader="$(readelf -l "$bin" 2>/dev/null | sed -n 's/.*interpreter: \(.*\)]/\1/p' | head -n1)"
    [ -n "$loader" ] && [ -e "$loader" ] && install -D "$loader" "$ROOTFS$loader" || true
  fi
}

echo "== 4. Минимальный rootfs =="
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/{bin,proc,tmp,etc,lib}
copy_with_libs "$(command -v busybox)" /bin/busybox
for applet in sh ls cat echo id sleep; do ln -sf busybox "$ROOTFS/bin/$applet"; done

QEMU_BIN=""
for cand in qemu-x86_64-static qemu-x86_64; do
  p="$(command -v "$cand" 2>/dev/null || true)"
  [ -n "$p" ] && { QEMU_BIN="$p"; break; }
done
if [ -z "$QEMU_BIN" ]; then
  QEMU_BIN="$(dpkg -L qemu-user qemu-user-static qemu-user-binfmt 2>/dev/null \
             | grep -E '/qemu-x86_64(-static)?$' | head -n1 || true)"
fi
if [ -z "$QEMU_BIN" ] || [ ! -x "$QEMU_BIN" ]; then
  echo "ОШИБКА: не найден исполняемый qemu-x86_64. Проверь: dpkg -L qemu-user | grep qemu-x86_64"
  exit 1
fi
echo "Транслятор: $QEMU_BIN"
copy_with_libs "$QEMU_BIN" /bin/qemu-x86_64
echo "SECRET: hostpass123" > "$ROOTFS/etc/shadow"
echo "ОК: rootfs в $ROOTFS"

echo "== 5. Тестовая x86-64 программа (гость) =="
cat > "$HERE/hello.c" <<'HELLO_EOF'
#include <stdio.h>
int main(void){ printf("Privet iz x86-64 gostya pod QEMU na ARM!\n"); return 0; }
HELLO_EOF
x86_64-linux-gnu-gcc -O2 -static "$HERE/hello.c" -o "$ROOTFS/hello"
echo "ОК: гость $ROOTFS/hello"
file "$ROOTFS/hello" | sed 's/^/    /'

echo "== 6. Файл политики (заглушка для уровня 3) =="
cat > "$HERE/policy.conf" <<'POLICY_EOF'
# policy.conf — политика уровня 3. Пока QEMU не пропатчен, не используется.
POLICY_EOF

cat <<MSG_EOF

========================================================================
ГОТОВО. Проверь уровень 4:

  # 1) обычный запуск гостя:
  "$QEMU_BIN" "$ROOTFS/hello"

  # 2) через твой запускатель (уровень 4):
  sudo "$HERE/sandbox" --rootfs "$ROOTFS" --policy "$HERE/policy.conf" -- /bin/qemu-x86_64 /hello

Оба должны напечатать строку про x86-64 гостя.
========================================================================
MSG_EOF
