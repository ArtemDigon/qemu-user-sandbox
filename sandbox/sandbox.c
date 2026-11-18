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
