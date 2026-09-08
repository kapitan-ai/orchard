#define _DARWIN_C_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define EX_TEMPFAIL 75
#define EX_IOERR 74
#define RELEASE_NAME "RELEASE_NAME=orchard_node_agent"
#define RELEASE_ROOT "RELEASE_ROOT=/Library/Application Support/Orchard/releases/orchard_node_agent"
#define BOOT_PREFIX "/Library/Application Support/Orchard/releases/orchard_node_agent/releases/"

struct process_identity {
  pid_t pid;
  long start_sec;
  int start_usec;
  dev_t device;
  ino_t inode;
  char executable[PROC_PIDPATHINFO_MAXSIZE];
};

static int read_identity(pid_t pid, struct process_identity *identity) {
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  struct kinfo_proc process;
  size_t process_size = sizeof(process);
  struct stat executable_stat;

  memset(&process, 0, sizeof(process));
  memset(identity, 0, sizeof(*identity));

  if (sysctl(mib, 4, &process, &process_size, NULL, 0) != 0) {
    return errno == ESRCH ? 1 : -1;
  }
  if (process_size == 0 || process.kp_proc.p_pid != pid) {
    return 1;
  }
  if (proc_pidpath(pid, identity->executable, sizeof(identity->executable)) <= 0) {
    return -1;
  }
  if (stat(identity->executable, &executable_stat) != 0) {
    return -1;
  }

  identity->pid = pid;
  identity->start_sec = process.kp_proc.p_starttime.tv_sec;
  identity->start_usec = process.kp_proc.p_starttime.tv_usec;
  identity->device = executable_stat.st_dev;
  identity->inode = executable_stat.st_ino;
  return 0;
}

static int has_suffix(const char *value, const char *suffix) {
  size_t value_size = strlen(value);
  size_t suffix_size = strlen(suffix);

  return value_size >= suffix_size &&
         strcmp(value + value_size - suffix_size, suffix) == 0;
}

static int trusted_release_executable(const char *executable) {
  char resolved[PATH_MAX];
  char component[PATH_MAX];
  char *slash;
  struct stat path_stat;

  if (realpath(executable, resolved) == NULL ||
      strncmp(resolved, RELEASE_ROOT "/", strlen(RELEASE_ROOT) + 1) != 0 ||
      strlen(resolved) >= sizeof(component)) {
    return 0;
  }

  strcpy(component, resolved);
  slash = strchr(component + 1, '/');
  while (slash != NULL) {
    char saved = *slash;
    *slash = '\0';
    if (lstat(component, &path_stat) != 0 ||
        !S_ISDIR(path_stat.st_mode) ||
        path_stat.st_uid != 0 ||
        (path_stat.st_mode & 0022) != 0) {
      return 0;
    }
    *slash = saved;
    slash = strchr(slash + 1, '/');
  }

  if (lstat(resolved, &path_stat) != 0 ||
      !S_ISREG(path_stat.st_mode) ||
      path_stat.st_uid != 0 ||
      (path_stat.st_mode & 0022) != 0) {
    return 0;
  }
  return 1;
}

static int process_is_node_agent(pid_t pid, const char *executable) {
  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  size_t size = 0;
  char *buffer;
  int has_release_name = 0;
  int has_release_identity = 0;

  if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size <= sizeof(int)) {
    return errno == ESRCH ? 0 : -1;
  }
  buffer = malloc(size);
  if (buffer == NULL) {
    return -1;
  }
  if (sysctl(mib, 3, buffer, &size, NULL, 0) != 0) {
    int result = errno == ESRCH ? 0 : -1;
    free(buffer);
    return result;
  }

  for (size_t index = sizeof(int); index < size;) {
    const char *token = buffer + index;
    size_t remaining = size - index;
    size_t token_size = strnlen(token, remaining);

    if (token_size == remaining) {
      free(buffer);
      return -1;
    }
    if (strcmp(token, RELEASE_NAME) == 0) {
      has_release_name = 1;
    }
    if (strcmp(token, RELEASE_ROOT) == 0 ||
        (strncmp(token, BOOT_PREFIX, strlen(BOOT_PREFIX)) == 0 &&
         (has_suffix(token, "/start") || has_suffix(token, "/start_clean")))) {
      has_release_identity = 1;
    }
    index += token_size + 1;
  }

  free(buffer);
  return has_release_name && has_release_identity &&
         trusted_release_executable(executable);
}

static int is_beam(const char *path) {
  const char *name = strrchr(path, '/');
  name = name == NULL ? path : name + 1;
  return strcmp(name, "beam.smp") == 0;
}

static void print_json_string(const char *value) {
  const unsigned char *cursor = (const unsigned char *)value;
  putchar('"');
  while (*cursor != '\0') {
    switch (*cursor) {
    case '"':
      fputs("\\\"", stdout);
      break;
    case '\\':
      fputs("\\\\", stdout);
      break;
    case '\n':
      fputs("\\n", stdout);
      break;
    case '\r':
      fputs("\\r", stdout);
      break;
    case '\t':
      fputs("\\t", stdout);
      break;
    default:
      if (*cursor < 0x20) {
        printf("\\u%04x", *cursor);
      } else {
        putchar(*cursor);
      }
    }
    cursor++;
  }
  putchar('"');
}

static void print_identity(const struct process_identity *identity) {
  printf("{\"pid\":%d,\"start_sec\":%ld,\"start_usec\":%d,"
         "\"device\":%llu,\"inode\":%llu,\"executable\":",
         identity->pid, identity->start_sec, identity->start_usec,
         (unsigned long long)identity->device,
         (unsigned long long)identity->inode);
  print_json_string(identity->executable);
  putchar('}');
}

static int command_signal(const char *pid_text, const char *sec_text,
                          const char *usec_text, const char *device_text,
                          const char *inode_text, const char *executable);

static long long monotonic_milliseconds(void) {
  struct timespec time;

  if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) {
    return -1;
  }
  return (long long)time.tv_sec * 1000 + time.tv_nsec / 1000000;
}

static int run_launchctl(int lock_descriptor, const char *action, const char *target) {
  int output_pipe[2];
  pid_t child;
  int status = 0;
  int flags;
  long long deadline;
  char output[4096];
  char chunk[1024];
  size_t output_size = 0;

  if (pipe(output_pipe) != 0) {
    return -1;
  }
  flags = fcntl(output_pipe[0], F_GETFL);
  if (flags < 0 || fcntl(output_pipe[0], F_SETFL, flags | O_NONBLOCK) != 0) {
    close(output_pipe[0]);
    close(output_pipe[1]);
    return -1;
  }
  child = fork();
  if (child < 0) {
    close(output_pipe[0]);
    close(output_pipe[1]);
    return -1;
  }
  if (child == 0) {
    close(lock_descriptor);
    close(output_pipe[0]);
    if (dup2(output_pipe[1], STDOUT_FILENO) < 0 ||
        dup2(output_pipe[1], STDERR_FILENO) < 0) {
      _exit(127);
    }
    close(output_pipe[1]);
    execl("/bin/launchctl", "launchctl", action, target, (char *)NULL);
    _exit(127);
  }

  close(output_pipe[1]);
  deadline = monotonic_milliseconds() + 10000;
  for (;;) {
    ssize_t read_size = read(output_pipe[0], chunk, sizeof(chunk));
    if (read_size > 0 && output_size < sizeof(output) - 1) {
      size_t available = sizeof(output) - output_size - 1;
      size_t copy_size = (size_t)read_size < available ? (size_t)read_size : available;
      memcpy(output + output_size, chunk, copy_size);
      output_size += copy_size;
    }
    if (waitpid(child, &status, WNOHANG) == child) {
      break;
    }
    if (monotonic_milliseconds() < 0 ||
        monotonic_milliseconds() >= deadline) {
      kill(child, SIGKILL);
      waitpid(child, &status, 0);
      close(output_pipe[0]);
      return -1;
    }
    usleep(10000);
  }
  for (;;) {
    ssize_t read_size = read(output_pipe[0], chunk, sizeof(chunk));
    if (read_size <= 0) {
      break;
    }
    if (output_size < sizeof(output) - 1) {
      size_t available = sizeof(output) - output_size - 1;
      size_t copy_size = (size_t)read_size < available ? (size_t)read_size : available;
      memcpy(output + output_size, chunk, copy_size);
      output_size += copy_size;
    }
  }
  close(output_pipe[0]);
  output[output_size] = '\0';

  if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
    return 0;
  }
  if (strstr(output, "Could not find service") != NULL ||
      strstr(output, "service not found") != NULL) {
    return 1;
  }
  return -1;
}

static int command_lock(const char *path) {
  int descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
  struct process_identity guard_identity;
  struct stat lock_stat;
  char buffer[PATH_MAX + 16];

  if (descriptor < 0) {
    return EX_IOERR;
  }
  if (fstat(descriptor, &lock_stat) != 0 || !S_ISREG(lock_stat.st_mode)) {
    close(descriptor);
    return EX_IOERR;
  }
  if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
    int code = errno == EWOULDBLOCK || errno == EAGAIN ? EX_TEMPFAIL : EX_IOERR;
    close(descriptor);
    return code;
  }
  if (fchmod(descriptor, 0600) != 0 ||
      (geteuid() == 0 && fchown(descriptor, 0, 0) != 0) ||
      fstat(descriptor, &lock_stat) != 0 ||
      read_identity(getpid(), &guard_identity) != 0) {
    flock(descriptor, LOCK_UN);
    close(descriptor);
    return EX_IOERR;
  }

  fputs("READY {\"guard_identity\":", stdout);
  print_identity(&guard_identity);
  printf(",\"lock_device\":%llu,\"lock_inode\":%llu}\n",
         (unsigned long long)lock_stat.st_dev,
         (unsigned long long)lock_stat.st_ino);
  fflush(stdout);
  while (fgets(buffer, sizeof(buffer), stdin) != NULL) {
    struct stat current;
    struct stat canonical;

    if (fstat(descriptor, &current) != 0 ||
        lstat(path, &canonical) != 0 ||
        !S_ISREG(canonical.st_mode) ||
        canonical.st_uid != geteuid() ||
        (canonical.st_mode & 0777) != 0600 ||
        canonical.st_nlink != 1 ||
        current.st_dev != lock_stat.st_dev ||
        current.st_ino != lock_stat.st_ino ||
        canonical.st_dev != lock_stat.st_dev ||
        canonical.st_ino != lock_stat.st_ino ||
        flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
      close(descriptor);
      return EX_IOERR;
    }

    if (strcmp(buffer, "CHECK\n") == 0) {
      fputs("LOCKED\n", stdout);
      fflush(stdout);
    } else if (strcmp(buffer, "BOOTOUT\n") == 0) {
      char plist[PATH_MAX + 1];
      int result;

      if (fgets(plist, sizeof(plist), stdin) == NULL) {
        close(descriptor);
        return EX_IOERR;
      }
      plist[strcspn(plist, "\n")] = '\0';
      result =
          plist[0] == '\0' ? -1 : run_launchctl(descriptor, "bootout", plist);
      if (result == 0) {
        fputs("BOOTED_OUT\n", stdout);
      } else if (result == 1) {
        fputs("BOOTOUT_ABSENT\n", stdout);
      } else {
        fputs("BOOTOUT_FAILED\n", stdout);
      }
      fflush(stdout);
    } else if (strcmp(buffer, "SIGNAL\n") == 0) {
      char pid[32];
      char sec[32];
      char usec[32];
      char device[32];
      char inode[32];
      char executable[PROC_PIDPATHINFO_MAXSIZE];
      int result;

      if (fgets(pid, sizeof(pid), stdin) == NULL ||
          fgets(sec, sizeof(sec), stdin) == NULL ||
          fgets(usec, sizeof(usec), stdin) == NULL ||
          fgets(device, sizeof(device), stdin) == NULL ||
          fgets(inode, sizeof(inode), stdin) == NULL ||
          fgets(executable, sizeof(executable), stdin) == NULL) {
        close(descriptor);
        return EX_IOERR;
      }
      pid[strcspn(pid, "\n")] = '\0';
      sec[strcspn(sec, "\n")] = '\0';
      usec[strcspn(usec, "\n")] = '\0';
      device[strcspn(device, "\n")] = '\0';
      inode[strcspn(inode, "\n")] = '\0';
      executable[strcspn(executable, "\n")] = '\0';
      result = command_signal(pid, sec, usec, device, inode, executable);
      if (result == 0) {
        fputs("SIGNALED\n", stdout);
      } else if (result == 3) {
        fputs("SIGNAL_EXITED\n", stdout);
      } else {
        fputs("SIGNAL_FAILED\n", stdout);
      }
      fflush(stdout);
    } else if (strcmp(buffer, "RELEASE\n") == 0) {
      if (flock(descriptor, LOCK_UN) != 0 || close(descriptor) != 0) {
        return EX_IOERR;
      }
      return 0;
    } else {
      flock(descriptor, LOCK_UN);
      close(descriptor);
      return EX_IOERR;
    }
  }
  close(descriptor);
  return 0;
}

/* proc_name requires same-user access. KERN_PROC_PID can classify an unrelated
 * process without reading its arguments or treating an unresolved path as exit. */
static int can_exclude_unresolved_process(pid_t pid, pid_t expected_pid) {
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  struct kinfo_proc process;
  size_t size = sizeof(process);
  size_t name_size;

  memset(&process, 0, sizeof(process));
  if (sysctl(mib, 4, &process, &size, NULL, 0) != 0) {
    return errno == ESRCH;
  }
  if (size == 0) {
    return 1;
  }
  if (size != sizeof(process) || process.kp_proc.p_pid != pid) {
    errno = EIO;
    return 0;
  }
  name_size = strnlen(process.kp_proc.p_comm, sizeof(process.kp_proc.p_comm));
  if (name_size == 0 || name_size == sizeof(process.kp_proc.p_comm)) {
    errno = EIO;
    return 0;
  }
  errno = 0;
  return pid != expected_pid && strcmp(process.kp_proc.p_comm, "beam.smp") != 0;
}

static int snapshot_error(const char *stage, pid_t pid, int error) {
  fprintf(stderr, "snapshot_failed stage=%s pid=%d errno=%d\n", stage, pid, error);
  return EX_IOERR;
}

static int command_snapshot(const char *expected_pid_text) {
  int byte_count = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
  int capacity;
  pid_t expected_pid = -1;
  int expected_seen = 0;
  pid_t *pids;
  int count;
  int emitted = 0;

  if (expected_pid_text != NULL) {
    char *end = NULL;
    long parsed = strtol(expected_pid_text, &end, 10);

    if (end == expected_pid_text || *end != '\0' || parsed <= 1 ||
        parsed > INT_MAX) {
      return snapshot_error("expected_pid", expected_pid, 0);
    }
    expected_pid = (pid_t)parsed;
  }
  if (byte_count <= 0 || byte_count > INT_MAX / 2) {
    return snapshot_error("list_size", 0, errno);
  }
  capacity = byte_count * 2;
  pids = calloc(1, (size_t)capacity);
  if (pids == NULL) {
    return snapshot_error("allocate", 0, errno);
  }
  byte_count = proc_listpids(PROC_ALL_PIDS, 0, pids, capacity);
  if (byte_count <= 0 || byte_count >= capacity) {
    free(pids);
    return snapshot_error("list_pids", 0, errno);
  }

  count = byte_count / (int)sizeof(pid_t);
  putchar('[');
  for (int index = 0; index < count; index++) {
    char executable[PROC_PIDPATHINFO_MAXSIZE];
    struct process_identity identity;
    int node_agent;
    int identity_result;

    if (pids[index] <= 1) {
      continue;
    }
    if (pids[index] == expected_pid) {
      expected_seen = 1;
    }
    if (proc_pidpath(pids[index], executable, sizeof(executable)) <= 0) {
      int path_error = errno;

      if (path_error == ESRCH ||
          can_exclude_unresolved_process(pids[index], expected_pid)) {
        continue;
      }
      int metadata_error = errno;
      pid_t pid = pids[index];
      free(pids);
      fprintf(stderr, "snapshot_path_failed pid=%d errno=%d metadata_errno=%d\n",
              pid, path_error, metadata_error);
      return snapshot_error("process_path", pid, path_error);
    }
    if (!is_beam(executable)) {
      if (pids[index] == expected_pid) {
        free(pids);
        return snapshot_error("expected_executable", expected_pid, 0);
      }
      continue;
    }
    node_agent =
        pids[index] == expected_pid ? 1 : process_is_node_agent(pids[index], executable);
    if (node_agent < 0) {
      int error = errno;
      pid_t pid = pids[index];
      free(pids);
      return snapshot_error("process_arguments", pid, error);
    }
    if (node_agent == 0) {
      continue;
    }
    identity_result = read_identity(pids[index], &identity);
    if (identity_result == 1) {
      continue;
    }
    if (identity_result != 0) {
      int error = errno;
      pid_t pid = pids[index];
      free(pids);
      return snapshot_error("process_identity", pid, error);
    }
    if (emitted != 0) {
      putchar(',');
    }
    print_identity(&identity);
    emitted++;
  }
  if (expected_pid > 1 && !expected_seen) {
    struct process_identity expected_identity;
    int expected_result = read_identity(expected_pid, &expected_identity);

    if (expected_result != 1) {
      if (expected_result != 0) {
        free(pids);
        return snapshot_error("expected_identity", expected_pid, errno);
      }
      if (emitted != 0) {
        putchar(',');
      }
      print_identity(&expected_identity);
    }
  }
  puts("]");
  free(pids);
  return 0;
}

static int command_identity_state(const char *pid_text, const char *sec_text,
                                  const char *usec_text) {
  char *pid_end = NULL;
  char *sec_end = NULL;
  char *usec_end = NULL;
  long pid = strtol(pid_text, &pid_end, 10);
  long sec = strtol(sec_text, &sec_end, 10);
  long usec = strtol(usec_text, &usec_end, 10);
  struct process_identity identity;
  int result;

  if (*pid_end != '\0' || *sec_end != '\0' || *usec_end != '\0' || pid <= 1 ||
      pid > INT_MAX) {
    return EX_IOERR;
  }
  result = read_identity((pid_t)pid, &identity);
  if (result == 1) {
    puts("EXITED");
    return 0;
  }
  if (result != 0) {
    puts("UNKNOWN");
    return 0;
  }
  if (identity.start_sec == sec && identity.start_usec == usec) {
    puts("ALIVE");
  } else {
    puts("REUSED");
  }
  return 0;
}

static int command_signal(const char *pid_text, const char *sec_text,
                          const char *usec_text, const char *device_text,
                          const char *inode_text, const char *executable) {
  char *pid_end = NULL;
  char *sec_end = NULL;
  char *usec_end = NULL;
  char *device_end = NULL;
  char *inode_end = NULL;
  long pid = strtol(pid_text, &pid_end, 10);
  long sec = strtol(sec_text, &sec_end, 10);
  long usec = strtol(usec_text, &usec_end, 10);
  unsigned long long device = strtoull(device_text, &device_end, 10);
  unsigned long long inode = strtoull(inode_text, &inode_end, 10);
  struct process_identity identity;
  int result;

  if (*pid_end != '\0' || *sec_end != '\0' || *usec_end != '\0' ||
      *device_end != '\0' || *inode_end != '\0' || pid <= 1 || pid > INT_MAX ||
      executable[0] == '\0') {
    return EX_IOERR;
  }
  result = read_identity((pid_t)pid, &identity);
  if (result == 1) {
    return 3;
  }
  if (result != 0) {
    return EX_IOERR;
  }
  if (identity.start_sec != sec || identity.start_usec != usec ||
      (unsigned long long)identity.device != device ||
      (unsigned long long)identity.inode != inode ||
      strcmp(identity.executable, executable) != 0) {
    return 4;
  }
  return kill((pid_t)pid, SIGTERM) == 0 ? 0 : EX_IOERR;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "lock") == 0) {
    return command_lock(argv[2]);
  }
  if ((argc == 2 || argc == 3) && strcmp(argv[1], "snapshot") == 0) {
    return command_snapshot(argc == 3 ? argv[2] : NULL);
  }
  if (argc == 5 && strcmp(argv[1], "identity-state") == 0) {
    return command_identity_state(argv[2], argv[3], argv[4]);
  }
  return 64;
}
