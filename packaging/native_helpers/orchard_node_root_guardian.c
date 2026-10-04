/*
 * Source-only Linux Node root guardian (SPEC 1.4, 4.9; ADR 0035).
 * ABI: --check-host; --run ROOT -- COMMAND [ARGS]; --verify ROOT MARKER PID;
 * --verify-preflight ROOT MARKER PID checks the launcher's direct child VM.
 * Marker: v1:<guardian-pid>:<child-pid>:<major>:<minor>:<inode>, all decimal.
 * Success is silent. Errors are bounded categories, never host/path contents.
 * Exit: 64 usage, 69 host, 73 root, 75 occupied, 77 verification, 70 internal;
 * --run otherwise returns the child's exit code or 128 + terminating signal.
 * The lock proves only per-root ownership, not enrollment, UUID uniqueness,
 * descendant cessation, resource release, or source/platform qualification.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <regex.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int refuse(int code, const char *category) {
  fprintf(stderr, "orchard-node-root-guardian: %s\n", category);
  return code;
}

#if defined(__linux__) || defined(ORCHARD_NODE_ROOT_GUARDIAN_TEST)
static int matches(const char *text, const char *pattern) {
  regex_t re;
  if (!text || strlen(text) > 8192 || regcomp(&re, pattern, REG_EXTENDED | REG_NOSUB))
    return 0;
  int ok = regexec(&re, text, 0, NULL, 0) == 0;
  regfree(&re);
  return ok;
}

struct host_facts {
  const char *id, *release, *codename, *arch, *kernel, *signature;
  const char *kernel_version, *kernel_source, *libc, *libc_package;
  const char *systemd_package, *server_package;
};

static int kernel_release(const char *release, unsigned *major, unsigned *minor,
                          unsigned *abi) {
  return matches(release,
    "^[1-9][0-9]{0,2}[.](0|[1-9][0-9]{0,2})[.]0-[1-9][0-9]{0,8}-generic$") &&
    sscanf(release, "%u.%u.0-%u-generic", major, minor, abi) == 3 &&
    (*major > 6 || (*major == 6 && *minor >= 8));
}

static void kernel_source_name(char *out, size_t size, unsigned major, unsigned minor) {
  if (major == 6 && minor == 8) snprintf(out, size, "linux-signed");
  else snprintf(out, size, "linux-signed-hwe-%u.%u", major, minor);
}

/* Numeric minima never admit a host without release-bound distro provenance. */
static int valid_host_facts(const struct host_facts *f) {
  const char *const fields[] = {f->id, f->release, f->codename, f->arch, f->kernel,
    f->signature, f->kernel_version, f->kernel_source, f->libc, f->libc_package,
    f->systemd_package, f->server_package};
  for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); i++)
    if (!fields[i] || !*fields[i] || strlen(fields[i]) > 512) return 0;
  if (strcmp(f->id, "ubuntu") || strcmp(f->release, "24.04") ||
      strcmp(f->codename, "noble") || strcmp(f->arch, "x86_64") ||
      strcmp(f->libc, "2.39") ||
      !matches(f->libc_package, "^2[.]39-0ubuntu8([.][0-9]+)?$") ||
      !matches(f->systemd_package, "^255[.]4-1ubuntu8([.][0-9]+)?$") ||
      !matches(f->server_package, "^1[.]539([.][0-9]+)?$")) return 0;
  unsigned major, minor, abi;
  if (!kernel_release(f->kernel, &major, &minor, &abi)) return 0;
  char source[80], version[160], signature[600];
  kernel_source_name(source, sizeof(source), major, minor);
  if (major == 6 && minor == 8) {
    snprintf(version, sizeof(version), "^6[.]8[.]0-%u[.][0-9]+$", abi);
  } else {
    snprintf(version, sizeof(version),
             "^%u[.]%u[.]0-%u[.][0-9]+~24[.]04[.][0-9]+$", major, minor, abi);
  }
  if (strcmp(f->kernel_source, source) || !matches(f->kernel_version, version)) return 0;
  snprintf(signature, sizeof(signature), "Ubuntu %s-generic ", f->kernel_version);
  size_t n = strlen(signature);
  char upstream[80];
  snprintf(upstream, sizeof(upstream), "^%u[.]%u[.][0-9]+\n$", major, minor);
  return !strncmp(f->signature, signature, n) &&
         matches(f->signature + n, upstream);
}

#ifdef ORCHARD_NODE_ROOT_GUARDIAN_TEST
static int test_host_validator(void) {
  struct host_facts good = {"ubuntu", "24.04", "noble", "x86_64",
    "6.8.0-90-generic", "Ubuntu 6.8.0-90.91-generic 6.8.12\n",
    "6.8.0-90.91", "linux-signed", "2.39", "2.39-0ubuntu8.6",
    "255.4-1ubuntu8.10", "1.539.2"};
  if (!valid_host_facts(&good)) return 1;
  good.kernel = "6.20.0-9-generic";
  good.kernel_version = "6.20.0-9.9~24.04.3";
  good.kernel_source = "linux-signed-hwe-6.20";
  good.signature = "Ubuntu 6.20.0-9.9~24.04.3-generic 6.20.1\n";
  if (!valid_host_facts(&good)) return 1;
  good.kernel = "7.0.0-9-generic";
  good.kernel_version = "7.0.0-9.9~24.04.5";
  good.kernel_source = "linux-signed-hwe-7.0";
  good.signature = "Ubuntu 7.0.0-9.9~24.04.5-generic 7.0.1\n";
  if (!valid_host_facts(&good)) return 1;
  /* Every required fact independently rejects missing/malformed evidence. */
  for (unsigned i = 0; i < 12; i++) {
    for (unsigned j = 0; j < 3; j++) {
      struct host_facts bad = good;
      const char *value = j == 0 ? NULL : j == 1 ? "" : "unknown\nextra";
      switch (i) {
        case 0: bad.id = value; break;
        case 1: bad.release = value; break;
        case 2: bad.codename = value; break;
        case 3: bad.arch = value; break;
        case 4: bad.kernel = value; break;
        case 5: bad.signature = value; break;
        case 6: bad.kernel_version = value; break;
        case 7: bad.kernel_source = value; break;
        case 8: bad.libc = value; break;
        case 9: bad.libc_package = value; break;
        case 10: bad.systemd_package = value; break;
        default: bad.server_package = value; break;
      }
      if (valid_host_facts(&bad)) return 1;
    }
  }
  struct host_facts bad = good;
  bad.release = "26.04";
  if (valid_host_facts(&bad)) return 1;
  bad = good; bad.kernel = "6.8.0-90-custom";
  if (valid_host_facts(&bad)) return 1;
  bad = good; bad.kernel_version = "6.8.0-91.91";
  if (valid_host_facts(&bad)) return 1;
  bad = good; bad.libc_package = "2.39-1";
  if (valid_host_facts(&bad)) return 1;
  bad = good; bad.id = "debian";
  if (valid_host_facts(&bad)) return 1;
  bad = good; bad.arch = "aarch64";
  if (valid_host_facts(&bad)) return 1;
  bad = good; bad.kernel = "6.6.0-90-generic";
  if (valid_host_facts(&bad)) return 1;
  bad = good; bad.kernel = "6.8.0-999999999999999999999-generic";
  if (valid_host_facts(&bad)) return 1;
  bad = good; bad.kernel = "6.8.0-microsoft-standard-WSL2";
  if (valid_host_facts(&bad)) return 1;
  bad = good; bad.libc = "2.38";
  if (valid_host_facts(&bad)) return 1;
  bad = good; bad.systemd_package = "254.4-1ubuntu8";
  if (valid_host_facts(&bad)) return 1;
  good.kernel = "6.14.0-37-generic";
  good.kernel_version = "6.14.0-37.37~24.04.1";
  good.kernel_source = "linux-signed-hwe-6.14";
  good.signature = "Ubuntu 6.14.0-37.37~24.04.1-generic 6.14.11\n";
  if (!valid_host_facts(&good)) return 1;
  good.kernel_version = "6.14.0-37.37~26.04.1";
  return valid_host_facts(&good) ? 1 : 0;
}
#endif
#endif

#ifdef __linux__
#include <fcntl.h>
#include <gnu/libc-version.h>
#include <grp.h>
#include <linux/magic.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/vfs.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int same_inode(const struct stat *a, const struct stat *b) {
  return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}

static int read_fd(int fd, char *out, size_t size) {
  size_t used = 0;
  while (used < size - 1) {
    ssize_t n = read(fd, out + used, size - 1 - used);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) return 0;
    if (!n) {
      if (memchr(out, '\0', used)) return 0;
      out[used] = '\0';
      return 1;
    }
    used += (size_t)n;
  }
  return 0;
}

static int read_at(int dir, const char *path, char *out, size_t size) {
  int fd = openat(dir, path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) return 0;
  int ok = read_fd(fd, out, size);
  close(fd);
  return ok;
}

static int number(const char *s, unsigned base, uint64_t max, uint64_t *out) {
  if (!s || !*s || strlen(s) > 20) return 0;
  uint64_t value = 0;
  for (; *s; s++) {
    unsigned digit = *s >= '0' && *s <= '9' ? (unsigned)(*s - '0') :
      base == 16 && *s >= 'a' && *s <= 'f' ? (unsigned)(*s - 'a' + 10) :
      base == 16 && *s >= 'A' && *s <= 'F' ? (unsigned)(*s - 'A' + 10) : 99;
    if (digit >= base || digit > max || value > (max - digit) / base) return 0;
    value = value * base + digit;
  }
  *out = value;
  return 1;
}

/* openat walks pinned ancestors, never resolving a symlink or dot alias. */
static int open_root(const char *path, struct stat *identity) {
  if (!path || path[0] != '/' || !path[1] || strlen(path) >= PATH_MAX ||
      path[strlen(path) - 1] == '/' || strstr(path, "//")) return -1;
  struct stat original, st;
  if (lstat(path, &original)) return -1;
  int fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  char copy[PATH_MAX];
  memcpy(copy, path + 1, strlen(path));
  char *save = NULL, *part = strtok_r(copy, "/", &save);
  while (fd >= 0 && part) {
    if (!strcmp(part, ".") || !strcmp(part, "..") || fstat(fd, &st) ||
        (st.st_uid != 0 && st.st_uid != geteuid()) ||
        ((st.st_mode & 0022) && !(st.st_uid == 0 && (st.st_mode & S_ISVTX)))) {
      close(fd); return -1;
    }
    int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    close(fd); fd = next;
    part = strtok_r(NULL, "/", &save);
  }
  struct statfs fs;
  if (fd < 0) return -1;
  if (fstat(fd, &st) || !same_inode(&st, &original) || st.st_uid != geteuid() ||
      (st.st_mode & 07777) != 0700 || fstatfs(fd, &fs) ||
      (fs.f_type != EXT4_SUPER_MAGIC && fs.f_type != XFS_SUPER_MAGIC)) {
    close(fd); return -1;
  }
  *identity = st;
  return fd;
}

static int root_unchanged(const char *path, const struct stat *held) {
  struct stat current;
  int fd = open_root(path, &current);
  if (fd < 0) return 0;
  close(fd);
  return same_inode(held, &current);
}

/* Read-only host probes use fixed absolute programs, a clean environment,
 * bounded output and a monotonic deadline. No shell or caller PATH. */
static int64_t milliseconds(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts)) return -1;
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int probe(char *const argv[], char *out, size_t size) {
  struct stat st;
  if (stat(argv[0], &st) || !S_ISREG(st.st_mode) || st.st_uid != 0 ||
      (st.st_mode & 0022)) return -1;
  int pipefd[2];
  if (pipe2(pipefd, O_CLOEXEC)) return -1;
  int64_t deadline = milliseconds();
  if (deadline < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }
  deadline += 3000;
  pid_t parent = getpid(), child = fork();
  if (!child) {
    close(pipefd[0]);
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent ||
        dup2(pipefd[1], STDOUT_FILENO) < 0 || dup2(pipefd[1], STDERR_FILENO) < 0)
      _exit(127);
    close(pipefd[1]);
    int nullfd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (nullfd < 0 || dup2(nullfd, STDIN_FILENO) < 0) _exit(127);
    if (nullfd > STDERR_FILENO) close(nullfd);
    char *const env[] = {"LANG=C", "LC_ALL=C", "PATH=/usr/bin:/bin", NULL};
    execve(argv[0], argv, env);
    _exit(127);
  }
  close(pipefd[1]);
  if (child < 0) { close(pipefd[0]); return -1; }
  size_t used = 0;
  int status = 0, ok = 0;
  for (;;) {
    int64_t now = milliseconds();
    if (now < 0 || now >= deadline || used == size - 1) break;
    struct pollfd p = {pipefd[0], POLLIN, 0};
    int ready = poll(&p, 1, (int)(deadline - now));
    if (ready < 0 && errno == EINTR) continue;
    if (ready <= 0) break;
    ssize_t n = read(pipefd[0], out + used, size - 1 - used);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) break;
    if (!n) { ok = 1; break; }
    used += (size_t)n;
  }
  close(pipefd[0]);
  /* EOF does not imply exit: retain the deadline for waitpid as well. */
  for (;;) {
    pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child) break;
    if (result < 0 && errno != EINTR) { ok = 0; break; }
    int64_t now = milliseconds();
    if (now < 0 || now >= deadline || !ok) {
      kill(child, SIGKILL);
      while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
      ok = 0; break;
    }
    struct timespec pause = {0, 10000000};
    nanosleep(&pause, NULL);
  }
  if (!ok || memchr(out, '\0', used) || !WIFEXITED(status)) return -1;
  out[used] = '\0';
  return WEXITSTATUS(status);
}

static int os_field(const char *text, const char *key, char *out, size_t size) {
  size_t keylen = strlen(key);
  int found = 0;
  for (const char *line = text; *line;) {
    const char *end = strchr(line, '\n');
    if (!end) return 0;
    if (!strncmp(line, key, keylen) && line[keylen] == '=') {
      if (found++) return 0;
      const char *start = line + keylen + 1;
      const char *stop = end;
      if (start < stop && *start == '"') {
        start++;
        if (start == stop || stop[-1] != '"') return 0;
        stop--;
      }
      size_t n = (size_t)(stop - start);
      if (!n || n >= size) return 0;
      memcpy(out, start, n); out[n] = '\0';
      if (!matches(out, "^[a-zA-Z0-9._-]+$")) return 0;
    }
    line = end + 1;
  }
  return found == 1;
}

static int package_version(const char *line, const char *name, const char *source,
                           char *version, size_t size) {
  char pkg[180], state[40], ver[180], src[180], srcver[180];
  int n = 0;
  if (sscanf(line, "%179[^\t]\t%39[^\t]\t%179[^\t]\t%179[^\t]\t%179[^\n]%n",
             pkg, state, ver, src, srcver, &n) != 5 || line[n] != '\n' ||
      strcmp(pkg, name) || strcmp(state, "install ok installed") ||
      strcmp(src, source) || strcmp(ver, srcver) || strlen(ver) >= size) return 0;
  strcpy(version, ver);
  return 1;
}

static int unprivileged(void) {
  uid_t real, effective, saved;
  gid_t gr, ge, gs;
  if (getresuid(&real, &effective, &saved) || !effective || real != effective ||
      saved != effective || getresgid(&gr, &ge, &gs) || gr != ge || gs != ge || !ge)
    return 0;
  if (access("/run/docker.sock", W_OK) == 0) return 0;
  if (errno != ENOENT && errno != EACCES) return 0;
  struct passwd *pw = getpwuid(effective);
  if (!pw || !matches(pw->pw_name, "^[a-z_][a-z0-9_-]{0,63}$") ||
      (strcmp(pw->pw_shell, "/usr/sbin/nologin") && strcmp(pw->pw_shell, "/sbin/nologin")))
    return 0;
  char username[65]; strcpy(username, pw->pw_name);
  gid_t groups[256];
  int count = getgroups(256, groups);
  if (count < 0) return 0;
  const char *const denied[] = {"root", "sudo", "wheel", "admin", "docker", "lxd", "incus", "disk"};
  for (int i = -1; i < count; i++) {
    struct group *g = getgrgid(i < 0 ? ge : groups[i]);
    if (!g) return 0;
    for (size_t j = 0; j < sizeof(denied) / sizeof(denied[0]); j++)
      if (!strcmp(g->gr_name, denied[j])) return 0;
  }
  /* Dropped supplementary groups do not erase the account's grants. */
  count = 256;
  if (getgrouplist(username, ge, groups, &count) < 0) return 0;
  for (int i = 0; i < count; i++) {
    struct group *g = getgrgid(groups[i]);
    if (!g) return 0;
    for (size_t j = 0; j < sizeof(denied) / sizeof(denied[0]); j++)
      if (!strcmp(g->gr_name, denied[j])) return 0;
  }
  char status[16384];
  if (!read_at(AT_FDCWD, "/proc/self/status", status, sizeof(status))) return 0;
  const char *const caps[] = {"CapInh:\t", "CapPrm:\t", "CapEff:\t", "CapAmb:\t"};
  for (size_t i = 0; i < sizeof(caps) / sizeof(caps[0]); i++) {
    char *p = strstr(status, caps[i]);
    if (!p || (p != status && p[-1] != '\n')) return 0;
    p += strlen(caps[i]);
    if (strncmp(p, "0000000000000000\n", 17)) return 0;
  }
  /* Group absence alone cannot exclude user-specific sudo rules. Unknown
   * (including password-required listings) is a refusal, never a no-grant. */
  struct stat sudo_st;
  if (lstat("/usr/bin/sudo", &sudo_st)) return errno == ENOENT;
  char output[4096], host[256], denial[512];
  char *const sudo_args[] = {"/usr/bin/sudo", "-n", "-l", NULL};
  if (probe(sudo_args, output, sizeof(output)) != 1 ||
      gethostname(host, sizeof(host)) || !memchr(host, '\0', sizeof(host))) return 0;
  snprintf(denial, sizeof(denial), "User %s is not allowed to run sudo on %s.\n", username, host);
  if (!strcmp(output, denial)) return 1;
  snprintf(denial, sizeof(denial), "Sorry, user %s may not run sudo on %s.\n", username, host);
  return !strcmp(output, denial);
}

static int check_host(void) {
  struct utsname u;
  char os[8192], id[32], release[32], codename[32], signature[1024], packages[8192];
  struct statfs procfs, cgroupfs;
  if (uname(&u) || strcmp(u.sysname, "Linux") ||
      statfs("/proc", &procfs) || procfs.f_type != PROC_SUPER_MAGIC ||
      statfs("/sys/fs/cgroup", &cgroupfs) || cgroupfs.f_type != CGROUP2_SUPER_MAGIC ||
      !read_at(AT_FDCWD, "/usr/lib/os-release", os, sizeof(os)) ||
      !os_field(os, "ID", id, sizeof(id)) ||
      !os_field(os, "VERSION_ID", release, sizeof(release)) ||
      !os_field(os, "VERSION_CODENAME", codename, sizeof(codename)) ||
      !read_at(AT_FDCWD, "/proc/version_signature", signature, sizeof(signature))) return 0;
  unsigned major = 0, minor = 0, abi = 0;
  if (!kernel_release(u.release, &major, &minor, &abi)) return 0;
  char kernel_pkg[180], kernel_source[80];
  snprintf(kernel_pkg, sizeof(kernel_pkg), "linux-image-%s", u.release);
  kernel_source_name(kernel_source, sizeof(kernel_source), major, minor);
  char *const query[] = {"/usr/bin/dpkg-query", "-W",
    "-f=${binary:Package}\t${Status}\t${Version}\t${source:Package}\t${source:Version}\n",
    kernel_pkg, "libc6:amd64", "systemd", "ubuntu-server", NULL};
  if (probe(query, packages, sizeof(packages))) return 0;
  char kv[180] = "", lv[180] = "", sv[180] = "", uv[180] = "";
  unsigned seen = 0;
  for (char *line = packages; *line;) {
    char *end = strchr(line, '\n');
    if (!end) return 0;
    unsigned bit;
    if (package_version(line, kernel_pkg, kernel_source, kv, sizeof(kv))) bit = 1;
    else if (package_version(line, "libc6:amd64", "glibc", lv, sizeof(lv))) bit = 2;
    else if (package_version(line, "systemd", "systemd", sv, sizeof(sv))) bit = 4;
    else if (package_version(line, "ubuntu-server", "ubuntu-meta", uv, sizeof(uv))) bit = 8;
    else return 0;
    if (seen & bit) return 0;
    seen |= bit; line = end + 1;
  }
  struct host_facts facts = {id, release, codename, u.machine, u.release, signature,
    kv, kernel_source, gnu_get_libc_version(), lv, sv, uv};
  if (seen != 15 || !valid_host_facts(&facts)) return 0;
  struct stat init, systemd;
  char data[8192];
  /* proc/1/exe is normally unreadable to a dedicated UID. PID 1's kernel
   * comm/cgroup, root ownership, and the distro binary supply readable facts. */
  if (stat("/proc/1", &init) || init.st_uid ||
      !read_at(AT_FDCWD, "/proc/1/comm", data, sizeof(data)) || strcmp(data, "systemd\n") ||
      stat("/usr/lib/systemd/systemd", &systemd) || !S_ISREG(systemd.st_mode) ||
      systemd.st_uid || (systemd.st_mode & 0022)) return 0;
  char *const version_args[] = {"/usr/lib/systemd/systemd", "--version", NULL};
  char version_line[256];
  snprintf(version_line, sizeof(version_line), "systemd 255 (%s)\n", sv);
  if (probe(version_args, data, sizeof(data)) || strncmp(data, version_line, strlen(version_line)))
    return 0;
  char *const virt[] = {"/usr/bin/systemd-detect-virt", "--container", NULL};
  if (probe(virt, data, sizeof(data)) != 1 || strcmp(data, "none\n")) return 0;
  const char *const markers[] = {"/.dockerenv", "/run/.containerenv", "/run/systemd/container"};
  for (size_t i = 0; i < sizeof(markers) / sizeof(markers[0]); i++) {
    struct stat st;
    if (!lstat(markers[i], &st) || errno != ENOENT) return 0;
  }
  if (!read_at(AT_FDCWD, "/proc/self/uid_map", data, sizeof(data)) ||
      !matches(data, "^[ ]*0[ ]+0[ ]+4294967295[ ]*\n$") ||
      !read_at(AT_FDCWD, "/proc/1/cgroup", data, sizeof(data)) || strcmp(data, "0::/init.scope\n"))
    return 0;
  return unprivileged();
}

struct marker { pid_t guardian, child; uint64_t major, minor, inode; };

static int parse_marker(const char *text, struct marker *m) {
  if (strlen(text) >= 160 || strncmp(text, "v1:", 3)) return 0;
  char copy[160]; strcpy(copy, text + 3);
  char *p = copy;
  uint64_t fields[5];
  for (unsigned i = 0; i < 5; i++) {
    char *end = strchr(p, ':');
    if ((i != 4) != (end != NULL)) return 0;
    if (end) *end = '\0';
    if (!number(p, 10, i < 2 ? INT_MAX : UINT64_MAX, &fields[i])) return 0;
    if (end) p = end + 1;
  }
  if (fields[0] < 2 || fields[1] < 2 || fields[0] == fields[1] || !fields[4]) return 0;
  m->guardian = (pid_t)fields[0]; m->child = (pid_t)fields[1];
  m->major = fields[2]; m->minor = fields[3]; m->inode = fields[4];
  return 1;
}

struct process { uint64_t start, parent; };

static int process_identity(int fd, pid_t pid, struct process *p) {
  char data[4096];
  if (!read_at(fd, "stat", data, sizeof(data))) return 0;
  char *left = strchr(data, '('), *right = strrchr(data, ')');
  if (!left || left == data || left[-1] != ' ' || !right || right < left || right[1] != ' ')
    return 0;
  left[-1] = '\0';
  uint64_t actual;
  if (!number(data, 10, INT_MAX, &actual) || actual != (uint64_t)pid) return 0;
  char *save = NULL, *token = strtok_r(right + 2, " \n", &save);
  if (!token || strlen(token) != 1 || !strchr("RSDTtIP", token[0])) return 0;
  for (unsigned field = 4; field <= 22; field++) {
    token = strtok_r(NULL, " \n", &save);
    if (!token) return 0;
    if (field == 4 && !number(token, 10, INT_MAX, &p->parent)) return 0;
    if (field == 22 && !number(token, 10, UINT64_MAX, &p->start)) return 0;
  }
  return p->start != 0;
}

static int open_process(pid_t pid) {
  char path[64]; snprintf(path, sizeof(path), "/proc/%ld", (long)pid);
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  struct stat st;
  if (fd >= 0 && (fstat(fd, &st) || st.st_uid != geteuid())) { close(fd); return -1; }
  return fd;
}

static int same_executable(int process, const struct stat *self) {
  /* procfs exe is deliberately followed, unlike any identity-root component. */
  int fd = openat(process, "exe", O_PATH | O_CLOEXEC);
  struct stat st;
  int ok = fd >= 0 && !fstat(fd, &st) && same_inode(&st, self) && st.st_nlink != 0;
  if (fd >= 0) close(fd);
  return ok;
}

static int locks_match(char *data, const struct marker *m) {
  int ok = 1, found = 0;
  char *line = data;
  while (ok && *line) {
    char *end = strchr(line, '\n');
    if (!end) { ok = 0; break; }
    *end = '\0';
    char *fields[10], *save = NULL;
    unsigned n = 0;
    for (char *t = strtok_r(line, " ", &save); t && n < 10; t = strtok_r(NULL, " ", &save))
      fields[n++] = t;
    if (n < 8 || n > 9) { ok = 0; break; }
    unsigned offset = !strcmp(fields[1], "->") ? 1 : 0;
    if (n != 8 + offset) { ok = 0; break; }
    size_t len = strlen(fields[0]); uint64_t number_value;
    if (!len || fields[0][len - 1] != ':') { ok = 0; break; }
    fields[0][len - 1] = '\0';
    if (!number(fields[0], 10, UINT64_MAX, &number_value)) { ok = 0; break; }
    char *kind = fields[1 + offset];
    if (strcmp(kind, "FLOCK")) {
      if (strcmp(kind, "POSIX") && strcmp(kind, "OFDLCK") && strcmp(kind, "LEASE")) {
        ok = 0; break;
      }
      line = end + 1; continue;
    }
    if (strcmp(fields[2 + offset], "ADVISORY") ||
        (strcmp(fields[3 + offset], "READ") && strcmp(fields[3 + offset], "WRITE")) ||
        strcmp(fields[6 + offset], "0") || strcmp(fields[7 + offset], "EOF")) {
      ok = 0; break;
    }
    uint64_t pid, maj, min, inode;
    char *device = fields[5 + offset], *colon1 = strchr(device, ':');
    char *colon2 = colon1 ? strchr(colon1 + 1, ':') : NULL;
    if (!colon2) { ok = 0; break; }
    *colon1 = '\0'; *colon2 = '\0';
    if (!number(fields[4 + offset], 10, INT_MAX, &pid) ||
        !number(device, 16, UINT_MAX, &maj) || !number(colon1 + 1, 16, UINT_MAX, &min) ||
        !number(colon2 + 1, 10, UINT64_MAX, &inode)) { ok = 0; break; }
    if (!offset && pid == (uint64_t)m->guardian && maj == m->major && min == m->minor &&
        inode == m->inode && !strcmp(fields[2], "ADVISORY") && !strcmp(fields[3], "WRITE") &&
        !strcmp(fields[6], "0") && !strcmp(fields[7], "EOF")) found++;
    line = end + 1;
  }
  return ok && found == 1;
}

static int owns_lock(const struct marker *m) {
  char *data = malloc(1024 * 1024);
  if (!data) return 0;
  int ok = read_at(AT_FDCWD, "/proc/locks", data, 1024 * 1024) && locks_match(data, m);
  free(data);
  return ok;
}

#ifdef ORCHARD_NODE_ROOT_GUARDIAN_TEST
static int test_parsers(void) {
  struct marker m;
  if (!parse_marker("v1:4321:8765:8:17:90210", &m)) return 1;
  const char *const invalid[] = {"", "v1:1:2:8:17:90210", "v1:4321:4321:8:17:90210",
    "v1:4321:8765:8:17:18446744073709551616", "v1:4321:8765:8::90210",
    "v1:+4321:8765:8:17:90210", "v1:4321:8765:8:17:90210:extra"};
  for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
    struct marker bad;
    if (parse_marker(invalid[i], &bad)) return 1;
  }
  const char *const records[] = {
    "1: FLOCK ADVISORY WRITE 4321 08:11:90210 0 EOF\n",
    "1: FLOCK ADVISORY WRITE 4321 08:11:90211 0 EOF\n",
    "1: FLOCK ADVISORY WRITE 4322 08:11:90210 0 EOF\n",
    "1: FLOCK ADVISORY READ 4321 08:11:90210 0 EOF\n",
    "1: -> FLOCK ADVISORY WRITE 4321 08:11:90210 0 EOF\n",
    "1: POSIX ADVISORY WRITE 4321 08:11:90210 0 EOF\n",
    "1: FLOCK ADVISORY WRITE 4321 08:zz:90210 0 EOF\n",
    "1: FLOCK ADVISORY WRITE 4321 08:11:90210 0 EOF extra\n",
    "1: FLOCK ADVISORY WRITE 4321 08:11:90210 0 EOF",
    "1: FLOCK ADVISORY WRITE 4321 08:11:90210 0 EOF\nmalformed\n", ""};
  for (size_t i = 0; i < sizeof(records) / sizeof(records[0]); i++) {
    char copy[256]; strcpy(copy, records[i]);
    if (locks_match(copy, &m) != (i == 0)) return 1;
  }
  return 0;
}
#endif

static int verify(const char *root, const char *text, const char *subject, int preflight) {
  struct marker m; uint64_t pid;
  if (!parse_marker(text, &m) || !number(subject, 10, INT_MAX, &pid) || pid < 2 ||
      (!preflight && pid != (uint64_t)m.child) || (preflight && pid == (uint64_t)m.child))
    return refuse(77, "verification_refused");
  struct stat identity, self;
  int rootfd = open_root(root, &identity);
  if (rootfd < 0) return refuse(77, "verification_refused");
  int guardian = open_process(m.guardian), child = open_process(m.child);
  int caller = preflight ? open_process((pid_t)pid) : -1;
  int executable = open("/proc/self/exe", O_PATH | O_CLOEXEC);
  struct process g1, g2, c1, c2;
  struct process p1, p2;
  int ok = guardian >= 0 && child >= 0 && executable >= 0 && !fstat(executable, &self) &&
    m.major == major(identity.st_dev) && m.minor == minor(identity.st_dev) &&
    m.inode == (uint64_t)identity.st_ino &&
    process_identity(guardian, m.guardian, &g1) && process_identity(child, m.child, &c1) &&
    c1.parent == (uint64_t)m.guardian &&
    (!preflight || (caller >= 0 && process_identity(caller, (pid_t)pid, &p1) &&
                    p1.parent == (uint64_t)m.child)) &&
    same_executable(guardian, &self) && owns_lock(&m) &&
    root_unchanged(root, &identity) &&
    process_identity(guardian, m.guardian, &g2) && process_identity(child, m.child, &c2) &&
    g1.start == g2.start && g1.parent == g2.parent && c1.start == c2.start &&
    c2.parent == (uint64_t)m.guardian &&
    (!preflight || (process_identity(caller, (pid_t)pid, &p2) &&
                    p1.start == p2.start && p2.parent == (uint64_t)m.child)) &&
    same_executable(guardian, &self) && owns_lock(&m) &&
    root_unchanged(root, &identity);
  close(rootfd);
  if (guardian >= 0) close(guardian);
  if (child >= 0) close(child);
  if (caller >= 0) close(caller);
  if (executable >= 0) close(executable);
  return ok ? 0 : refuse(77, "verification_refused");
}

static int link_parent(pid_t parent) {
  return prctl(PR_SET_PDEATHSIG, SIGKILL) == 0 && getppid() == parent;
}

#ifdef ORCHARD_NODE_ROOT_GUARDIAN_TEST
/* Real fork/prctl race, forced before prctl rather than relying on a sleep.
 * Subreaping is confined to this test driver, never the production guardian. */
static int test_parent_race(void) {
  int gate[2], report[2];
  if (prctl(PR_SET_CHILD_SUBREAPER, 1) || pipe2(gate, O_CLOEXEC) || pipe2(report, O_CLOEXEC))
    return 1;
  pid_t guardian = fork();
  if (guardian < 0) return 1;
  if (!guardian) {
    close(gate[1]); close(report[0]);
    pid_t parent = getpid(), child = fork();
    if (child < 0) _exit(1);
    if (!child) {
      close(report[1]);
      char byte;
      if (read(gate[0], &byte, 1) != 1) _exit(2);
      close(gate[0]);
      _exit(link_parent(parent) ? 3 : 0);
    }
    close(gate[0]);
    if (write(report[1], &child, sizeof(child)) != (ssize_t)sizeof(child)) _exit(1);
    close(report[1]);
    _exit(0);
  }
  close(gate[0]); close(report[1]);
  pid_t child = 0;
  ssize_t n = read(report[0], &child, sizeof(child));
  close(report[0]);
  int status;
  if (waitpid(guardian, &status, 0) != guardian || !WIFEXITED(status) || WEXITSTATUS(status) ||
      n != (ssize_t)sizeof(child) || child < 2) { close(gate[1]); return 1; }
  if (write(gate[1], "x", 1) != 1) { close(gate[1]); return 1; }
  close(gate[1]);
  return waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 1;
}
#endif

static int run(const char *root, char **command) {
  struct stat identity;
  int fd = open_root(root, &identity);
  if (fd < 0) return refuse(73, "root_refused");
  if (flock(fd, LOCK_EX | LOCK_NB)) {
    int occupied = errno == EWOULDBLOCK || errno == EAGAIN;
    close(fd); return refuse(occupied ? 75 : 73, occupied ? "root_occupied" : "root_refused");
  }
  if (!root_unchanged(root, &identity)) { close(fd); return refuse(73, "root_changed"); }
  sigset_t signals, old;
  sigemptyset(&signals);
  const int watched[] = {SIGCHLD, SIGTERM, SIGHUP, SIGINT, SIGQUIT};
  for (size_t i = 0; i < sizeof(watched) / sizeof(watched[0]); i++) sigaddset(&signals, watched[i]);
  if (sigprocmask(SIG_BLOCK, &signals, &old)) { close(fd); return refuse(70, "signal_failed"); }
  /* Reset inherited SIGCHLD=SIG_IGN before forking, so waitpid remains valid. */
  struct sigaction action;
  memset(&action, 0, sizeof(action)); action.sa_handler = SIG_DFL;
  sigemptyset(&action.sa_mask);
  for (size_t i = 0; i < sizeof(watched) / sizeof(watched[0]); i++) {
    if (sigaction(watched[i], &action, NULL)) { close(fd); return refuse(70, "signal_failed"); }
  }
  pid_t parent = getpid(), child = fork();
  if (child < 0) { close(fd); return refuse(70, "fork_failed"); }
  if (!child) {
    close(fd);
    if (!link_parent(parent)) _exit(70);
    char marker[160];
    snprintf(marker, sizeof(marker), "v1:%ld:%ld:%u:%u:%llu", (long)parent, (long)getpid(),
             major(identity.st_dev), minor(identity.st_dev), (unsigned long long)identity.st_ino);
    if (!root_unchanged(root, &identity) ||
        setenv("ORCHARD_NODE_ROOT_GUARD", marker, 1) ||
        setenv("ORCHARD_NODE_IDENTITY_ROOT", root, 1) || sigprocmask(SIG_SETMASK, &old, NULL))
      _exit(70);
    execvp(command[0], command);
    _exit(errno == ENOENT ? 127 : 126);
  }
  int status;
  for (;;) {
    pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child) break;
    if (result < 0 && errno != EINTR) { close(fd); return refuse(70, "wait_failed"); }
    int signal = sigwaitinfo(&signals, NULL);
    if (signal == SIGTERM || signal == SIGHUP) (void)kill(child, signal);
    else if (signal < 0 && errno != EINTR) {
      (void)kill(child, SIGKILL);
      while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
      close(fd); return refuse(70, "signal_failed");
    }
  }
  close(fd);
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 70;
}
#endif

int main(int argc, char **argv) {
#ifdef ORCHARD_NODE_ROOT_GUARDIAN_TEST
  if (argc == 2 && !strcmp(argv[1], "--test-host-validator")) return test_host_validator();
#ifdef __linux__
  if (argc == 2 && !strcmp(argv[1], "--test-parsers")) return test_parsers();
  if (argc == 2 && !strcmp(argv[1], "--test-parent-race")) return test_parent_race();
#endif
#endif
  int check = argc == 2 && !strcmp(argv[1], "--check-host");
  int launch = argc >= 5 && !strcmp(argv[1], "--run") && !strcmp(argv[3], "--");
  int verification = argc == 5 && !strcmp(argv[1], "--verify");
  int preflight = argc == 5 && !strcmp(argv[1], "--verify-preflight");
  if (!check && !launch && !verification && !preflight) return refuse(64, "usage");
#ifndef __linux__
  return refuse(69, "unsupported_platform");
#else
#ifdef ORCHARD_NODE_ROOT_GUARDIAN_TEST
  /* Only this separately named build bypasses host facts. Keep production's
   * collector compiled, and expose it to fixture tests without bypass. */
  if (check) return check_host() ? 0 : refuse(69, "host_refused");
#else
  if (!check_host()) return refuse(69, "host_refused");
#endif
  if (check) return 0;
  if (launch) return run(argv[2], argv + 4);
  return verify(argv[2], argv[3], argv[4], preflight);
#endif
}
