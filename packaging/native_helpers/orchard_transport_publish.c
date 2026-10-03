/*
 * orchard-transport-publish: private-stage publication of the local-CA
 * certificate and endpoint metadata for `orchardctl transport
 * enable-local-https`. See docs/decisions/0036-private-stage-local-ca-publication.md.
 *
 * Protocol: 4-byte big-endian length-prefixed frames on stdin/stdout.
 *   PREPARE\n<absolute support root>   -> OK PREPARED <public> <endpoint> <stage>
 *   PUBLISH\n<u32 len><ca><u32 len><endpoint> -> OK PUBLISHED [cleanup_retained=<stage>]
 *   ROLLBACK                           -> OK ROLLED_BACK [cleanup_retained=<stage>]
 *   COMMIT                             -> OK COMMITTED
 *   ABORT                              -> OK ABORTED
 * Every ERR reply is terminal: ERR <code> <errno> <subject> [detail]
 */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#elif defined(__linux__)
#define _GNU_SOURCE
#else
#error "orchard-transport-publish is qualified only for Darwin and Linux"
#endif

#include <sys/types.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#include <sys/acl.h>
#include <sys/mount.h>
#include <sys/param.h>
#else
#include <linux/magic.h>
#include <sys/vfs.h>
#include <sys/xattr.h>
#endif

#define PROTOCOL_VERSION "1"
#define FRAME_LIMIT (1024U * 1024U)
#define ARTIFACT_LIMIT (256U * 1024U)
#define STAGE_PREFIX ".orchard-public-stage-"
#define PUBLIC_NAME "public"
#define CA_NAME "ca.crt"
#define ENDPOINT_NAME "endpoint.json"
#define CONFIG_NAME "config"
#define LOCK_WAIT_MS 90000L

enum phase { PHASE_INIT, PHASE_PREPARED, PHASE_PUBLISHED, PHASE_ROLLED_BACK };

struct identity {
  dev_t dev;
  ino_t ino;
};

struct staged_file {
  const char *name;
  struct identity id;
  int created;
};

struct stage {
  char name[64];
  int fd;
  struct identity id;
  int owned;
  struct staged_file files[2];
};

static const char *fail_code = "internal_error";
static const char *fail_subject = "helper";
static int fail_errno;
static char fail_detail[512];

static enum phase phase = PHASE_INIT;
static uid_t owner_uid;
static int support_fd = -1;
static int public_fd = -1;
static int config_fd = -1;
static struct identity config_id;
static struct stat support_st;
static int public_existed;
static int ca_existed;
static struct identity ca_existing;
static int endpoint_existed;
static struct identity endpoint_existing;
static unsigned char *snapshot;
static size_t snapshot_len;
static mode_t snapshot_mode;
static struct identity endpoint_published;
static int endpoint_was_published;
static int publication_visible;
static int protocol_mode;
static struct stage stage = {.fd = -1};
static char reply_note[128];

static int fail(const char *subject, const char *code, int err) {
  fail_subject = subject;
  fail_code = code;
  fail_errno = err;
  fail_detail[0] = '\0';
  return -1;
}

static int fail_detailed(const char *subject, const char *code, int err, const char *detail) {
  fail(subject, code, err);
  snprintf(fail_detail, sizeof(fail_detail), "%s", detail);
  return -1;
}

static void append_detail(const char *extra) {
  size_t used = strlen(fail_detail);
  snprintf(fail_detail + used, sizeof(fail_detail) - used, "%s%s", used ? " " : "", extra);
}

#ifdef ORCHARD_TRANSPORT_PUBLISH_TEST
static int fault(const char *kind, const char *subject) {
  const char *wanted = getenv("ORCHARD_TRANSPORT_PUBLISH_TEST_FAULT");
  char point[128];

  if (!wanted) return 0;
  snprintf(point, sizeof(point), "%s:%s", kind, subject);
  return strcmp(wanted, point) == 0;
}

static int list_contains(const char *list, const char *item) {
  size_t item_len = strlen(item);
  const char *cursor = list;

  while (cursor && *cursor) {
    const char *end = strchr(cursor, ',');
    size_t len = end ? (size_t)(end - cursor) : strlen(cursor);
    if (len == item_len && strncmp(cursor, item, len) == 0) return 1;
    cursor = end ? end + 1 : NULL;
  }
  return 0;
}

static void pause_at(const char *point) {
  const char *dir = getenv("ORCHARD_TRANSPORT_PUBLISH_TEST_PAUSE_DIR");
  const char *wanted = getenv("ORCHARD_TRANSPORT_PUBLISH_TEST_PAUSE");
  char ready[PATH_MAX], go[PATH_MAX];
  struct timespec delay = {0, 10000000L};
  int fd;

  if (!dir || !wanted || !list_contains(wanted, point)) return;
  snprintf(ready, sizeof(ready), "%s/%s.ready", dir, point);
  snprintf(go, sizeof(go), "%s/%s.go", dir, point);
  fd = open(ready, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) _exit(70);
  if (dprintf(fd, "%s\n", stage.name) < 0) _exit(70);
  close(fd);
  for (int i = 0; i < 6000; i++) {
    if (access(go, F_OK) == 0) return;
    nanosleep(&delay, NULL);
  }
  _exit(70);
}
#else
static int fault(const char *kind, const char *subject) {
  (void)kind;
  (void)subject;
  return 0;
}

static void pause_at(const char *point) { (void)point; }
#endif

static const char *errno_name(int err) {
  static const struct {
    int value;
    const char *name;
  } names[] = {
      {EACCES, "eacces"},   {EPERM, "eperm"},         {ENOENT, "enoent"},
      {ENOTDIR, "enotdir"}, {EISDIR, "eisdir"},       {ELOOP, "eloop"},
      {EEXIST, "eexist"},   {EXDEV, "exdev"},         {EIO, "eio"},
      {ENOTSUP, "enotsup"}, {EOPNOTSUPP, "enotsup"},  {ENODATA, "enodata"},
      {ENOSPC, "enospc"},   {EROFS, "erofs"},         {EINVAL, "einval"},
      {EBUSY, "ebusy"},     {ENOTEMPTY, "enotempty"}, {ENAMETOOLONG, "enametoolong"},
      {ERANGE, "erange"},   {E2BIG, "e2big"},         {ENOSYS, "enosys"},
      {EBADF, "ebadf"},     {EINTR, "eintr"},         {EAGAIN, "eagain"},
      {ENOMEM, "enomem"},   {EMLINK, "emlink"},       {EDQUOT, "edquot"},
  };
  static char fallback[32];

  if (err == 0) return "-";
  for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
    if (names[i].value == err) return names[i].name;
  }
  snprintf(fallback, sizeof(fallback), "errno%d", err);
  return fallback;
}

static int same_identity(const struct stat *st, struct identity id) {
  return st->st_dev == id.dev && st->st_ino == id.ino;
}

static struct identity identity_of(const struct stat *st) {
  struct identity id = {st->st_dev, st->st_ino};
  return id;
}

/* Returns 1 when no ACL is present, 0 when one is, and -1 when inspection failed. */
#ifdef __APPLE__
static int acl_state(int fd, int is_directory, const char *subject) {
  filesec_t security;
  struct stat bound;
  int present = -1;
  int inspected;
  int saved;

  (void)is_directory;
  if (fault("acl_error", subject)) {
    errno = EIO;
    return -1;
  }
  if (fault("acl_present", subject)) return 0;
  security = filesec_init();
  if (!security) return -1;
  inspected = fstatx_np(fd, &bound, security) == 0 &&
              filesec_query_property(security, FILESEC_ACL, &present) == 0;
  saved = errno;
  filesec_free(security);
  errno = saved;
  if (!inspected) return -1;
  return present == 0 ? 1 : 0;
}

static int ownership_honored(int fd) {
  struct statfs fs;
  if (fstatfs(fd, &fs) != 0) return -1;
  return (fs.f_flags & MNT_IGNORE_OWNERSHIP) ? 0 : 1;
}

/* Returns 1 for a qualified filesystem, 0 for an unqualified one, -1 on inspection failure. */
static int filesystem_state(int fd, const char *subject) {
  struct statfs fs;

  if (fault("fs_error", subject)) {
    errno = EIO;
    return -1;
  }
  if (fault("fs_unqualified", subject)) return 0;
  if (fstatfs(fd, &fs) != 0) return -1;
  if (!(fs.f_flags & MNT_LOCAL) || (fs.f_flags & (MNT_IGNORE_OWNERSHIP | MNT_UNION))) return 0;
  if (strcmp(fs.f_fstypename, "apfs") != 0 && strcmp(fs.f_fstypename, "hfs") != 0) return 0;
  errno = 0;
  return fpathconf(fd, _PC_EXTENDED_SECURITY_NP) == 1 ? 1 : (errno ? -1 : 0);
}
#else
static int acl_state(int fd, int is_directory, const char *subject) {
  static const char *const attrs[] = {"system.posix_acl_access", "system.posix_acl_default"};
  size_t count = is_directory ? 2 : 1;

  if (fault("acl_error", subject)) {
    errno = EIO;
    return -1;
  }
  if (fault("acl_present", subject)) return 0;
  for (size_t i = 0; i < count; i++) {
    if (fgetxattr(fd, attrs[i], NULL, 0) >= 0) return 0;
    if (errno != ENODATA) return -1;
  }
  return 1;
}

static int ownership_honored(int fd) {
  (void)fd;
  return 1;
}

static int filesystem_state(int fd, const char *subject) {
  struct statfs fs;

  if (fault("fs_error", subject)) {
    errno = EIO;
    return -1;
  }
  if (fault("fs_unqualified", subject)) return 0;
  if (fstatfs(fd, &fs) != 0) return -1;
  if (fs.f_type == EXT4_SUPER_MAGIC) return 1;
#ifdef ORCHARD_TRANSPORT_PUBLISH_TEST
  if (fs.f_type == TMPFS_MAGIC) return 1;
#endif
  return 0;
}
#endif

static int check_acl(int fd, int is_directory, const char *subject) {
  int state = acl_state(fd, is_directory, subject);
  if (state < 0) return fail(subject, "acl_inspection_failed", errno);
  if (state == 0) return fail(subject, "acl_present", 0);
  return 0;
}

static int check_filesystem(int fd, const char *subject) {
  int state = filesystem_state(fd, subject);
  if (state < 0) return fail(subject, "filesystem_inspection_failed", errno);
  if (state == 0) return fail(subject, "filesystem_unqualified", 0);
  return 0;
}

static int check_ancestor(int fd, const char *prefix) {
  struct stat st;
  int honored;

  if (fstat(fd, &st) != 0) return fail_detailed("ancestor", "inspection_failed", errno, prefix);
  if (!S_ISDIR(st.st_mode)) return fail_detailed("ancestor", "not_directory", ENOTDIR, prefix);
  if (st.st_uid != 0 && st.st_uid != owner_uid)
    return fail_detailed("ancestor", "unsafe_owner", 0, prefix);
  if ((st.st_mode & 0022) && !(st.st_uid == 0 && (st.st_mode & S_ISVTX)))
    return fail_detailed("ancestor", "writable", 0, prefix);
  honored = ownership_honored(fd);
  if (honored < 0) return fail_detailed("ancestor", "filesystem_inspection_failed", errno, prefix);
  if (honored == 0) return fail_detailed("ancestor", "ownership_ignored", 0, prefix);
  if (check_acl(fd, 1, "ancestor") != 0) {
    append_detail(prefix);
    return -1;
  }
  return 0;
}

static int check_private_directory(int fd, const char *subject, struct stat *out) {
  if (fstat(fd, out) != 0) return fail(subject, "inspection_failed", errno);
  if (!S_ISDIR(out->st_mode)) return fail(subject, "not_directory", ENOTDIR);
  if (out->st_uid != owner_uid) return fail(subject, "unsafe_owner", 0);
  if (out->st_mode & 0022) return fail(subject, "writable", 0);
  if (out->st_mode & S_ISGID) return fail(subject, "setgid", 0);
  if (check_filesystem(fd, subject) != 0) return -1;
  return check_acl(fd, 1, subject);
}

static int check_private_entry(int dirfd, const char *name, const char *subject, int directory,
                               mode_t private_mask, int *fd_out) {
  struct stat named, bound;
  int fd;

  if (fd_out) *fd_out = -1;
  if (fstatat(dirfd, name, &named, AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno == ENOENT) return 1;
    return fail_detailed(subject, "inspection_failed", errno, name);
  }
  if (S_ISLNK(named.st_mode)) return fail_detailed(subject, "symlink", ELOOP, name);
  if (directory && !S_ISDIR(named.st_mode))
    return fail_detailed(subject, "not_directory", ENOTDIR, name);
  if (!directory && !S_ISREG(named.st_mode)) return fail_detailed(subject, "not_regular", 0, name);
  if (named.st_uid != owner_uid) return fail_detailed(subject, "unsafe_owner", 0, name);
  fd = openat(dirfd, name,
              O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : O_NONBLOCK));
  if (fd < 0) return fail_detailed(subject, "inspection_failed", errno, name);
  if (fstat(fd, &bound) != 0 || !same_identity(&bound, identity_of(&named))) {
    close(fd);
    return fail_detailed(subject, "identity_mismatch", 0, name);
  }
  if (bound.st_uid != owner_uid) {
    close(fd);
    return fail_detailed(subject, "unsafe_owner", 0, name);
  }
  if (bound.st_mode & 0022) {
    close(fd);
    return fail_detailed(subject, "writable", 0, name);
  }
  if (bound.st_mode & private_mask) {
    close(fd);
    return fail_detailed(subject, "not_private", 0, name);
  }
  if (bound.st_mode & (directory ? S_ISGID : (S_ISUID | S_ISGID | S_ISVTX))) {
    close(fd);
    return fail_detailed(subject, directory ? "setgid" : "special_mode", 0, name);
  }
  if (bound.st_dev != support_st.st_dev) {
    close(fd);
    return fail_detailed(subject, "cross_device", EXDEV, name);
  }
  if (check_acl(fd, directory, subject) != 0) {
    close(fd);
    append_detail(name);
    return -1;
  }
  if (fd_out)
    *fd_out = fd;
  else
    close(fd);
  return 0;
}

static int check_config(void) {
  static const char *const tls_sources[] = {"ca.key", "ca.crt", "controller.crt", "controller.key",
                                            ".orchard-tls-meta.json"};
  struct stat st;
  int tls_fd;
  int state = check_private_entry(support_fd, CONFIG_NAME, "config", 1, 0077, &config_fd);

  if (state != 0) return state < 0 ? -1 : 0;
  if (fstat(config_fd, &st) != 0) return fail("config", "inspection_failed", errno);
  config_id = identity_of(&st);
  if (check_private_entry(config_fd, "controller.env", "controller_env", 0, 0, NULL) < 0)
    return -1;
  state = check_private_entry(config_fd, "tls", "tls", 1, 0, &tls_fd);
  if (state < 0) return -1;
  if (state == 1) return 0;
  for (size_t i = 0; i < sizeof(tls_sources) / sizeof(tls_sources[0]); i++) {
    if (check_private_entry(tls_fd, tls_sources[i], "tls_source", 0, 0, NULL) < 0) {
      close(tls_fd);
      return -1;
    }
  }
  close(tls_fd);
  return 0;
}

static int config_unchanged(void) {
  struct stat st;

  if (config_fd < 0) return 0;
  if (fstatat(support_fd, CONFIG_NAME, &st, AT_SYMLINK_NOFOLLOW) != 0 ||
      !same_identity(&st, config_id))
    return fail("config", "identity_mismatch", errno);
  return 0;
}

static int classify_open_failure(int dirfd, const char *name, const char *subject, int err,
                                 const char *detail) {
  struct stat st;

  if (fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
    if (S_ISLNK(st.st_mode)) return fail_detailed(subject, "symlink", ELOOP, detail);
    if (!S_ISDIR(st.st_mode)) return fail_detailed(subject, "not_directory", ENOTDIR, detail);
  }
  if (err == ENOENT) return fail_detailed(subject, "missing", ENOENT, detail);
  return fail_detailed(subject, "inspection_failed", err, detail);
}

static int open_support_root(const char *path) {
  char buffer[PATH_MAX];
  char prefix[PATH_MAX];
  char *cursor;
  size_t length = strlen(path);
  int fd;

  if (path[0] != '/' || length < 2 || length >= sizeof(buffer) || path[length - 1] == '/')
    return fail("support_root", "path_invalid", EINVAL);
  memcpy(buffer, path, length + 1);
  fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return fail_detailed("ancestor", "inspection_failed", errno, "/");
  if (check_ancestor(fd, "/") != 0) {
    close(fd);
    return -1;
  }
  prefix[0] = '\0';
  cursor = buffer + 1;
  while (cursor) {
    char *slash = strchr(cursor, '/');
    int last = slash == NULL;
    int next;

    if (slash) *slash = '\0';
    if (*cursor == '\0' || strcmp(cursor, ".") == 0 || strcmp(cursor, "..") == 0) {
      close(fd);
      return fail("support_root", "path_invalid", EINVAL);
    }
    snprintf(prefix + strlen(prefix), sizeof(prefix) - strlen(prefix), "/%s", cursor);
    next = openat(fd, cursor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (next < 0) {
      int err = errno;
      classify_open_failure(fd, cursor, last ? "support_root" : "ancestor", err, prefix);
      close(fd);
      return -1;
    }
    close(fd);
    fd = next;
    if (!last && check_ancestor(fd, prefix) != 0) {
      close(fd);
      return -1;
    }
    cursor = slash ? slash + 1 : NULL;
  }
  return fd;
}

static int inspect_existing_file(const char *name, const char *subject, int *existed,
                                 struct identity *id, int take_snapshot) {
  struct stat named, bound;
  int fd;

  *existed = 0;
  if (fstatat(public_fd, name, &named, AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno == ENOENT) return 0;
    return fail(subject, "inspection_failed", errno);
  }
  if (S_ISLNK(named.st_mode)) return fail(subject, "symlink", ELOOP);
  if (!S_ISREG(named.st_mode)) return fail(subject, "not_regular", 0);
  if (named.st_uid != owner_uid) return fail(subject, "unsafe_owner", 0);
  fd = openat(public_fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return fail(subject, "inspection_failed", errno);
  if (fstat(fd, &bound) != 0 || !same_identity(&bound, identity_of(&named))) {
    close(fd);
    return fail(subject, "identity_mismatch", 0);
  }
  if (bound.st_uid != owner_uid) {
    close(fd);
    return fail(subject, "unsafe_owner", 0);
  }
  if (bound.st_mode & 0022) {
    close(fd);
    return fail(subject, "writable", 0);
  }
  if (bound.st_mode & (S_ISUID | S_ISGID | S_ISVTX)) {
    close(fd);
    return fail(subject, "special_mode", 0);
  }
  if (bound.st_dev != support_st.st_dev) {
    close(fd);
    return fail(subject, "cross_device", EXDEV);
  }
  if (check_acl(fd, 0, subject) != 0) {
    close(fd);
    return -1;
  }
  if (take_snapshot) {
    size_t total = 0;

    if (bound.st_size < 0 || (uintmax_t)bound.st_size > ARTIFACT_LIMIT) {
      close(fd);
      return fail(subject, "too_large", EFBIG);
    }
    snapshot_len = (size_t)bound.st_size;
    snapshot = malloc(snapshot_len ? snapshot_len : 1);
    if (!snapshot) {
      close(fd);
      return fail(subject, "inspection_failed", ENOMEM);
    }
    while (total < snapshot_len) {
      ssize_t got = pread(fd, snapshot + total, snapshot_len - total, (off_t)total);
      if (got < 0 && errno == EINTR) continue;
      if (got <= 0) {
        int err = got < 0 ? errno : EIO;
        close(fd);
        return fail(subject, "inspection_failed", err);
      }
      total += (size_t)got;
    }
    snapshot_mode = bound.st_mode & 0777;
  }
  close(fd);
  *existed = 1;
  *id = identity_of(&bound);
  return 0;
}

static void describe_retained(const char *name, const struct stat *st) {
  char detail[256];

  if (st)
    snprintf(detail, sizeof(detail), "retained=%s dev=%llu ino=%llu mode=%04o", name,
             (unsigned long long)st->st_dev, (unsigned long long)st->st_ino,
             (unsigned)(st->st_mode & 07777));
  else
    snprintf(detail, sizeof(detail), "retained=%s", name);
  append_detail(detail);
}

static int create_stage(void) {
  unsigned char random_bytes[16];
  struct stat bound, named;
  size_t used;
  int err;

  memset(&stage, 0, sizeof(stage));
  stage.fd = -1;
  if (getentropy(random_bytes, sizeof(random_bytes)) != 0)
    return fail("stage", "create_failed", errno);
  used = (size_t)snprintf(stage.name, sizeof(stage.name), "%s", STAGE_PREFIX);
  for (size_t i = 0; i < sizeof(random_bytes); i++)
    used += (size_t)snprintf(stage.name + used, sizeof(stage.name) - used, "%02x",
                             (unsigned)random_bytes[i]);
  if (fault("create_error", "stage")) return fail("stage", "create_failed", EIO);
  if (mkdirat(support_fd, stage.name, 0700) != 0) return fail("stage", "create_failed", errno);
  pause_at("after_stage_mkdir");
  stage.fd = openat(support_fd, stage.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  err = errno;
  if (stage.fd < 0 || fstat(stage.fd, &bound) != 0) {
    fail("stage", "postcheck_failed", stage.fd < 0 ? err : errno);
    describe_retained(stage.name,
                      fstatat(support_fd, stage.name, &named, AT_SYMLINK_NOFOLLOW) == 0 ? &named
                                                                                       : NULL);
    return -1;
  }
  if (fstatat(support_fd, stage.name, &named, AT_SYMLINK_NOFOLLOW) != 0 ||
      !same_identity(&named, identity_of(&bound)) || bound.st_dev != support_st.st_dev ||
      !S_ISDIR(bound.st_mode) || (bound.st_mode & 07777) != 0700 || bound.st_uid != owner_uid) {
    fail("stage", "postcheck_failed", 0);
    describe_retained(stage.name, &bound);
    return -1;
  }
  if (check_filesystem(stage.fd, "stage") != 0 || check_acl(stage.fd, 1, "stage") != 0) {
    fail_code = "postcheck_failed";
    describe_retained(stage.name, &bound);
    return -1;
  }
  stage.id = identity_of(&bound);
  stage.owned = 1;
  return 0;
}

static int write_all(int fd, const unsigned char *bytes, size_t length) {
  size_t written = 0;

  while (written < length) {
    ssize_t count = write(fd, bytes + written, length - written);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return -1;
    written += (size_t)count;
  }
  return 0;
}

static int stage_file(struct staged_file *slot, const char *name, const unsigned char *bytes,
                      size_t length, int *out_fd) {
  struct stat st;
  int fd;

  slot->name = name;
  fd = openat(stage.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) return fail("stage", "write_failed", errno);
  if (fstat(fd, &st) != 0) {
    int err = errno;
    close(fd);
    return fail("stage", "write_failed", err);
  }
  slot->id = identity_of(&st);
  slot->created = 1;
  if (!S_ISREG(st.st_mode) || st.st_uid != owner_uid || (st.st_mode & 0077)) {
    close(fd);
    return fail("stage", "postcheck_failed", 0);
  }
  if (fault("write_error", name)) {
    close(fd);
    return fail("stage", "write_failed", EIO);
  }
  if (write_all(fd, bytes, length) != 0 || fsync(fd) != 0) {
    int err = errno;
    close(fd);
    return fail("stage", "write_failed", err);
  }
  *out_fd = fd;
  return 0;
}

static int protect_file(int fd, mode_t final_mode) {
  struct stat st;
  int err;

  if (fchmod(fd, final_mode) != 0 || fstat(fd, &st) != 0) {
    err = errno;
    close(fd);
    return fail("stage", "write_failed", err);
  }
  close(fd);
  if ((st.st_mode & 07777) != final_mode) return fail("stage", "postcheck_failed", 0);
  return 0;
}

static int cleanup_stage(void) {
  struct stat st;
  int retained = 0;

  if (!stage.owned) return 0;
  for (size_t i = 0; i < sizeof(stage.files) / sizeof(stage.files[0]); i++) {
    struct staged_file *slot = &stage.files[i];
    if (!slot->created) continue;
    if (fstatat(stage.fd, slot->name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
      if (errno != ENOENT) retained = 1;
      continue;
    }
    if (!same_identity(&st, slot->id) || unlinkat(stage.fd, slot->name, 0) != 0) retained = 1;
  }
  if (fstatat(support_fd, stage.name, &st, AT_SYMLINK_NOFOLLOW) != 0 ||
      !same_identity(&st, stage.id) || unlinkat(support_fd, stage.name, AT_REMOVEDIR) != 0)
    retained = 1;
  close(stage.fd);
  stage.fd = -1;
  stage.owned = 0;
  return retained ? -1 : 0;
}

static void cleanup_after_failure(void) {
  char name[sizeof(stage.name)];

  if (publication_visible) append_detail("public_state=visible");
  memcpy(name, stage.name, sizeof(name));
  if (stage.owned && cleanup_stage() != 0) {
    char detail[128];
    snprintf(detail, sizeof(detail), "cleanup_retained=%s", name);
    append_detail(detail);
  }
}

/* Before the whole stage becomes public/, it must hold exactly the files this helper staged. */
static int stage_holds_only_staged_files(void) {
  struct dirent *entry;
  struct stat st;
  int fd = dup(stage.fd);
  DIR *dir;

  if (fd < 0) return fail("stage", "inspection_failed", errno);
  dir = fdopendir(fd);
  if (!dir) {
    int err = errno;
    close(fd);
    return fail("stage", "inspection_failed", err);
  }
  rewinddir(dir);
  while ((entry = readdir(dir)) != NULL) {
    int expected = 0;

    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    for (size_t i = 0; i < sizeof(stage.files) / sizeof(stage.files[0]); i++) {
      struct staged_file *slot = &stage.files[i];
      if (slot->created && strcmp(entry->d_name, slot->name) == 0 &&
          fstatat(stage.fd, slot->name, &st, AT_SYMLINK_NOFOLLOW) == 0 &&
          same_identity(&st, slot->id))
        expected = 1;
    }
    if (!expected) {
      fail_detailed("stage", "unexpected_entry", 0, entry->d_name);
      closedir(dir);
      return -1;
    }
  }
  closedir(dir);
  return 0;
}

static int rename_noreplace(int from_dir, const char *from, int to_dir, const char *to) {
#ifdef __APPLE__
  return renameatx_np(from_dir, from, to_dir, to, RENAME_EXCL);
#else
  return renameat2(from_dir, from, to_dir, to, RENAME_NOREPLACE);
#endif
}

static int target_unchanged(const char *name, int existed, struct identity expected) {
  struct stat st;

  if (fstatat(public_fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0)
    return errno == ENOENT && !existed ? 0 : fail("publication", "identity_mismatch", errno);
  if (!existed || !same_identity(&st, expected))
    return fail_detailed("publication", "identity_mismatch", 0, name);
  return 0;
}

static int install_file(struct staged_file *slot, int existed, struct identity expected) {
  struct stat st;

  if (target_unchanged(slot->name, existed, expected) != 0) return -1;
  if (fault("rename_error", slot->name)) return fail("publication", "rename_failed", EIO);
  if (renameat(stage.fd, slot->name, public_fd, slot->name) != 0)
    return fail("publication", "rename_failed", errno);
  slot->created = 0;
  publication_visible = 1;
  if (fstatat(public_fd, slot->name, &st, AT_SYMLINK_NOFOLLOW) != 0 ||
      !same_identity(&st, slot->id))
    return fail_detailed("publication", "identity_mismatch", errno, slot->name);
  return 0;
}

/* After publication the stage holds no published entry, so retained residue is reported, not fatal. */
static void cleanup_published_stage(void) {
  char name[sizeof(stage.name)];

  memcpy(name, stage.name, sizeof(name));
  if (cleanup_stage() != 0) snprintf(reply_note, sizeof(reply_note), "cleanup_retained=%s", name);
}

static int widen_public_profile(void) {
  if (fault("mode_error", PUBLIC_NAME)) return fail("public", "mode_failed", EIO);
  if (fchmod(public_fd, 0755) != 0) return fail("public", "mode_failed", errno);
  if (fchmod(support_fd, 0711) != 0) return fail("support_root", "mode_failed", errno);
  (void)fsync(public_fd);
  (void)fsync(support_fd);
  return 0;
}

static long elapsed_ms(const struct timespec *start) {
  struct timespec now;

  clock_gettime(CLOCK_MONOTONIC, &now);
  return (long)(now.tv_sec - start->tv_sec) * 1000L + (now.tv_nsec - start->tv_nsec) / 1000000L;
}

static long lock_wait_limit_ms(void) {
#ifdef ORCHARD_TRANSPORT_PUBLISH_TEST
  const char *override = getenv("ORCHARD_TRANSPORT_PUBLISH_TEST_LOCK_WAIT_MS");
  if (override) return strtol(override, NULL, 10);
#endif
  return LOCK_WAIT_MS;
}

/* A protocol client that disconnects while waiting ends the wait before any stage exists. */
static int exit_if_client_gone(void) {
  struct pollfd input = {STDIN_FILENO, POLLIN, 0};
  unsigned char byte;
  ssize_t got;

  if (!protocol_mode || poll(&input, 1, 0) <= 0) return 0;
  got = read(STDIN_FILENO, &byte, 1);
  if (got <= 0) _exit(0);
  return fail("protocol", "protocol_error", EINVAL);
}

static int lock_support_root(void) {
  struct timespec start, delay = {0, 50000000L};
  long limit = lock_wait_limit_ms();

  clock_gettime(CLOCK_MONOTONIC, &start);
  for (;;) {
    if (flock(support_fd, LOCK_EX | LOCK_NB) == 0) return 0;
    if (errno == EINTR) continue;
    if (errno != EWOULDBLOCK) return fail("lock", "lock_failed", errno);
    if (elapsed_ms(&start) >= limit) return fail("lock", "lock_timeout", EWOULDBLOCK);
    if (exit_if_client_gone() != 0) return -1;
    nanosleep(&delay, NULL);
  }
}

static int prepare(const char *path) {
  struct stat named, public_st;
  int endpoint_state_existed;

  support_fd = open_support_root(path);
  if (support_fd < 0) return -1;
  if (check_private_directory(support_fd, "support_root", &support_st) != 0) return -1;
  if (lock_support_root() != 0) return -1;
  if (check_private_directory(support_fd, "support_root", &support_st) != 0) return -1;
  if (check_config() != 0) return -1;

  if (fstatat(support_fd, PUBLIC_NAME, &named, AT_SYMLINK_NOFOLLOW) == 0) {
    if (S_ISLNK(named.st_mode)) return fail("public", "symlink", ELOOP);
    if (!S_ISDIR(named.st_mode)) return fail("public", "not_directory", ENOTDIR);
    public_fd = openat(support_fd, PUBLIC_NAME, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (public_fd < 0)
      return classify_open_failure(support_fd, PUBLIC_NAME, "public", errno, PUBLIC_NAME);
    if (check_private_directory(public_fd, "public", &public_st) != 0) return -1;
    if (!same_identity(&public_st, identity_of(&named)))
      return fail("public", "identity_mismatch", 0);
    if (public_st.st_dev != support_st.st_dev) return fail("public", "cross_device", EXDEV);
    if (inspect_existing_file(CA_NAME, "ca", &ca_existed, &ca_existing, 0) != 0) return -1;
    if (inspect_existing_file(ENDPOINT_NAME, "endpoint", &endpoint_state_existed,
                              &endpoint_existing, 1) != 0)
      return -1;
    endpoint_existed = endpoint_state_existed;
    public_existed = 1;
  } else if (errno != ENOENT) {
    return fail("public", "inspection_failed", errno);
  }

  if (create_stage() != 0) return -1;
  pause_at("after_stage_create");
  phase = PHASE_PREPARED;
  return 0;
}

static int publish(const unsigned char *ca, size_t ca_len, const unsigned char *endpoint,
                   size_t endpoint_len) {
  struct staged_file *ca_slot = &stage.files[0];
  struct staged_file *endpoint_slot = &stage.files[1];
  int ca_fd = -1, endpoint_fd = -1;
  struct stat st;

  if (endpoint_len == 0) return fail("protocol", "protocol_error", EINVAL);
  if (config_unchanged() != 0) return -1;
  if (ca_len > 0 && stage_file(ca_slot, CA_NAME, ca, ca_len, &ca_fd) != 0) return -1;
  if (stage_file(endpoint_slot, ENDPOINT_NAME, endpoint, endpoint_len, &endpoint_fd) != 0) {
    if (ca_fd >= 0) close(ca_fd);
    return -1;
  }
  pause_at("after_stage_write");
  if (ca_fd >= 0 && protect_file(ca_fd, 0644) != 0) {
    close(endpoint_fd);
    return -1;
  }
  if (protect_file(endpoint_fd, 0644) != 0) return -1;
  pause_at("after_file_protect");

  if (!public_existed) {
    if (stage_holds_only_staged_files() != 0) return -1;
    pause_at("before_public_rename");
    if (fault("rename_error", PUBLIC_NAME)) return fail("publication", "rename_failed", EIO);
    if (rename_noreplace(support_fd, stage.name, support_fd, PUBLIC_NAME) != 0)
      return fail("publication", errno == EEXIST || errno == ENOTEMPTY ? "conflict" : "rename_failed",
                  errno);
    stage.owned = 0;
    publication_visible = 1;
    if (fstatat(support_fd, PUBLIC_NAME, &st, AT_SYMLINK_NOFOLLOW) != 0 ||
        !same_identity(&st, stage.id))
      return fail("publication", "identity_mismatch", errno);
    public_fd = stage.fd;
    stage.fd = -1;
  } else {
    if (ca_slot->name && install_file(ca_slot, ca_existed, ca_existing) != 0) return -1;
    if (install_file(endpoint_slot, endpoint_existed, endpoint_existing) != 0) return -1;
  }
  endpoint_published = endpoint_slot->id;
  endpoint_was_published = 1;
  if (widen_public_profile() != 0) return -1;
  phase = PHASE_PUBLISHED;
  cleanup_published_stage();
  return 0;
}

static int rollback(void) {
  struct stat st;
  struct staged_file *slot;
  int fd;

  if (!endpoint_was_published) return fail("protocol", "protocol_error", EINVAL);
  if (fstatat(public_fd, ENDPOINT_NAME, &st, AT_SYMLINK_NOFOLLOW) != 0)
    return fail_detailed("rollback", "identity_mismatch", errno, "endpoint=absent");
  if (!same_identity(&st, endpoint_published)) {
    fail("rollback", "identity_mismatch", 0);
    describe_retained(ENDPOINT_NAME, &st);
    return -1;
  }
  if (!endpoint_existed) {
    if (fault("unlink_error", ENDPOINT_NAME)) return fail("rollback", "unlink_failed", EIO);
    if (unlinkat(public_fd, ENDPOINT_NAME, 0) != 0) return fail("rollback", "unlink_failed", errno);
    phase = PHASE_ROLLED_BACK;
    return 0;
  }
  if (create_stage() != 0) return -1;
  slot = &stage.files[1];
  if (stage_file(slot, ENDPOINT_NAME, snapshot, snapshot_len, &fd) != 0)
    return -1;
  if (protect_file(fd, snapshot_mode) != 0) return -1;
  if (install_file(slot, 1, endpoint_published) != 0) return -1;
  phase = PHASE_ROLLED_BACK;
  cleanup_published_stage();
  return 0;
}

static int read_exact(unsigned char *buffer, size_t length) {
  size_t total = 0;

  while (total < length) {
    ssize_t got = read(STDIN_FILENO, buffer + total, length - total);
    if (got < 0 && errno == EINTR) continue;
    if (got <= 0) return total == 0 && got == 0 ? 0 : -1;
    total += (size_t)got;
  }
  return 1;
}

static uint32_t decode_u32(const unsigned char *bytes) {
  return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) |
         (uint32_t)bytes[3];
}

/* Returns 1 with a frame, 0 on clean end of input, -1 on a malformed frame. */
static int read_frame(unsigned char **frame, size_t *length) {
  unsigned char header[4];
  int status = read_exact(header, sizeof(header));
  uint32_t size;

  if (status <= 0) return status;
  size = decode_u32(header);
  if (size == 0 || size > FRAME_LIMIT) return -1;
  *frame = malloc(size + 1U);
  if (!*frame) return -1;
  if (read_exact(*frame, size) != 1) {
    free(*frame);
    return -1;
  }
  (*frame)[size] = '\0';
  *length = size;
  return 1;
}

static void write_frame(const char *text) {
  size_t length = strlen(text);
  unsigned char header[4] = {(unsigned char)(length >> 24), (unsigned char)(length >> 16),
                             (unsigned char)(length >> 8), (unsigned char)length};
  if (fault("write_error", "reply") || write_all(STDOUT_FILENO, header, sizeof(header)) != 0 ||
      write_all(STDOUT_FILENO, (const unsigned char *)text, length) != 0) {
    if (stage.owned) (void)cleanup_stage();
    _exit(74);
  }
}

static void reply_error(void) {
  char line[1024];

  snprintf(line, sizeof(line), "ERR %s %s %s%s%s", fail_code, errno_name(fail_errno),
           fail_subject, fail_detail[0] ? " " : "", fail_detail);
  write_frame(line);
}

static void reply_ok(const char *status) {
  char line[256];

  snprintf(line, sizeof(line), "OK %s%s%s", status, reply_note[0] ? " " : "", reply_note);
  write_frame(line);
}

static void finish_failure(void) {
  cleanup_after_failure();
  reply_error();
  exit(1);
}

static int parse_publish(const unsigned char *frame, size_t length, const unsigned char **ca,
                         size_t *ca_len, const unsigned char **endpoint, size_t *endpoint_len) {
  size_t offset = strlen("PUBLISH\n");
  uint32_t size;

  if (length < offset + 4) return -1;
  size = decode_u32(frame + offset);
  offset += 4;
  if (size > ARTIFACT_LIMIT || length - offset < (size_t)size + 4) return -1;
  *ca = frame + offset;
  *ca_len = size;
  offset += size;
  size = decode_u32(frame + offset);
  offset += 4;
  if (size > ARTIFACT_LIMIT || length - offset != (size_t)size) return -1;
  *endpoint = frame + offset;
  *endpoint_len = size;
  return 0;
}

static int handle(unsigned char *frame, size_t length) {
  char line[256];

  if (length > 8 && memcmp(frame, "PREPARE\n", 8) == 0 && phase == PHASE_INIT) {
    if (memchr(frame, '\0', length)) return fail("protocol", "protocol_error", EINVAL);
    if (prepare((const char *)frame + 8) != 0) return -1;
    snprintf(line, sizeof(line), "OK PREPARED %s %s %s", public_existed ? "existing" : "absent",
             endpoint_existed ? "existing" : "absent", stage.name);
    write_frame(line);
    return 0;
  }
  if (length > 8 && memcmp(frame, "PUBLISH\n", 8) == 0 && phase == PHASE_PREPARED) {
    const unsigned char *ca, *endpoint;
    size_t ca_len, endpoint_len;
    if (parse_publish(frame, length, &ca, &ca_len, &endpoint, &endpoint_len) != 0)
      return fail("protocol", "protocol_error", EINVAL);
    if (publish(ca, ca_len, endpoint, endpoint_len) != 0) return -1;
    reply_ok("PUBLISHED");
    return 0;
  }
  if (length == 8 && memcmp(frame, "ROLLBACK", 8) == 0 && phase == PHASE_PUBLISHED) {
    reply_note[0] = '\0';
    if (rollback() != 0) return -1;
    reply_ok("ROLLED_BACK");
    return 0;
  }
  if (length == 6 && memcmp(frame, "COMMIT", 6) == 0 &&
      (phase == PHASE_PUBLISHED || phase == PHASE_ROLLED_BACK)) {
    write_frame("OK COMMITTED");
    exit(0);
  }
  if (length == 5 && memcmp(frame, "ABORT", 5) == 0 && phase == PHASE_PREPARED) {
    if (cleanup_stage() != 0) {
      fail("cleanup", "retained", 0);
      describe_retained(stage.name, NULL);
      return -1;
    }
    write_frame("OK ABORTED");
    exit(0);
  }
  return fail("protocol", "protocol_error", EINVAL);
}

#ifdef ORCHARD_TRANSPORT_PUBLISH_TEST
static unsigned char *read_file(const char *path, size_t *length) {
  unsigned char *buffer = malloc(ARTIFACT_LIMIT);
  size_t total = 0;
  int fd = open(path, O_RDONLY | O_CLOEXEC);

  if (!buffer || fd < 0) exit(66);
  for (;;) {
    ssize_t got = read(fd, buffer + total, ARTIFACT_LIMIT - total);
    if (got < 0 && errno == EINTR) continue;
    if (got < 0) exit(66);
    if (got == 0) break;
    total += (size_t)got;
    if (total == ARTIFACT_LIMIT) exit(66);
  }
  close(fd);
  *length = total;
  return buffer;
}

static int oneshot(const char *root, const char *ca_path, const char *endpoint_path) {
  size_t ca_len, endpoint_len;
  unsigned char *ca = read_file(ca_path, &ca_len);
  unsigned char *endpoint = read_file(endpoint_path, &endpoint_len);

  if (prepare(root) != 0 || publish(ca, ca_len, endpoint, endpoint_len) != 0) {
    char line[1024];
    cleanup_after_failure();
    snprintf(line, sizeof(line), "ERR %s %s %s%s%s\n", fail_code, errno_name(fail_errno),
             fail_subject, fail_detail[0] ? " " : "", fail_detail);
    fputs(line, stdout);
    return 1;
  }
  printf("OK PUBLISHED%s%s\n", reply_note[0] ? " " : "", reply_note);
  return 0;
}
#endif

int main(int argc, char **argv) {
  owner_uid = geteuid();
  signal(SIGPIPE, SIG_IGN);
#ifdef ORCHARD_TRANSPORT_PUBLISH_TEST
  if (argc == 5 && strcmp(argv[1], "--oneshot") == 0) return oneshot(argv[2], argv[3], argv[4]);
#endif
  if (argc != 3 || strcmp(argv[1], "--protocol") != 0 || strcmp(argv[2], PROTOCOL_VERSION) != 0)
    return 64;
  protocol_mode = 1;

  for (;;) {
    unsigned char *frame = NULL;
    size_t length = 0;
    int status = read_frame(&frame, &length);

    if (status == 0) {
      if (phase == PHASE_PREPARED) (void)cleanup_stage();
      return 0;
    }
    if (status < 0) {
      fail("protocol", "protocol_error", EINVAL);
      finish_failure();
    }
    if (handle(frame, length) != 0) {
      free(frame);
      finish_failure();
    }
    free(frame);
  }
}
