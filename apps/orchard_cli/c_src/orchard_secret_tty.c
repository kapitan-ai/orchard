#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define FRAME_LIMIT 16384U
#define HANDSHAKE_TIMEOUT_MS 1000
#define DISCARD_QUIET_MS 500

#define CONTROL_READY 'R'
#define CONTROL_ENTER 'E'
#define CONTROL_PROTECTED 'P'
#define CONTROL_DONE 'D'
#define CONTROL_RESTORED 'O'
#define CONTROL_ABORT 'A'
#define CONTROL_FAILED 'F'
#define CONTROL_QUIESCE 'Q'
#define CONTROL_QUIESCED 'q'

static struct termios saved_state;
static int tty_fd = -1;
static pid_t target_foreground_group = -1;
static pid_t owner_pid = -1;
static pid_t supervisor_pid = -1;
static pid_t watchdog_pid = -1;
static struct timeval owner_start_time;
static struct timeval supervisor_start_time;
static int owner_identity_initialized = 0;
static int supervisor_identity_initialized = 0;
static volatile sig_atomic_t signal_write_fd = -1;
static int completion_dir_fd = -1;
static int completion_registered = 0;

#ifdef ORCHARD_SECRET_TTY_TEST
enum test_fault {
  TEST_FAULT_NONE,
  TEST_FAULT_PARTIAL_PROTECT,
  TEST_FAULT_POST_PROTECT,
  TEST_FAULT_SIGNAL_INT,
  TEST_FAULT_SIGNAL_HUP,
  TEST_FAULT_SIGNAL_TERM,
  TEST_FAULT_SIGNAL_KILL,
  TEST_FAULT_MARKER_PRE_READY_KILL,
  TEST_FAULT_WATCHDOG_HANDSHAKE,
  TEST_FAULT_WATCHDOG_CUSTODY_HANDSHAKE,
  TEST_FAULT_WATCHDOG_PROTECTED_HANDSHAKE,
  TEST_FAULT_RESTORER_PARENT_KILL,
  TEST_FAULT_RESTORER_PRE_TEARDOWN_KILL,
  TEST_FAULT_RESTORER_IDENTITY_RETRY,
  TEST_FAULT_RESTORER_SIGNAL_SETUP,
  TEST_FAULT_WATCHDOG_IDLE,
  TEST_FAULT_WATCHDOG_READ
};
static enum test_fault active_test_fault = TEST_FAULT_NONE;
#endif

static int write_all(int fd, const void *buffer, size_t length) {
  const unsigned char *cursor = buffer;

  while (length > 0) {
    ssize_t count = write(fd, cursor, length);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return -1;
    cursor += count;
    length -= (size_t)count;
  }
  return 0;
}

static int read_all(int fd, void *buffer, size_t length) {
  unsigned char *cursor = buffer;

  while (length > 0) {
    ssize_t count = read(fd, cursor, length);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) return -1;
    if (count == 0) return 0;
    cursor += count;
    length -= (size_t)count;
  }
  return 1;
}

static int send_byte(int fd, unsigned char value) {
  return write_all(fd, &value, 1U);
}

static int receive_byte(int fd, unsigned char *value) {
  return read_all(fd, value, 1U);
}

static int send_frame(const void *payload, size_t length) {
  if (length > FRAME_LIMIT) return -1;
  uint32_t header = htonl((uint32_t)length);
  if (write_all(STDOUT_FILENO, &header, sizeof(header)) != 0) return -1;
  return write_all(STDOUT_FILENO, payload, length);
}

static int receive_frame(unsigned char *payload, size_t *length) {
  uint32_t header;
  int status = read_all(STDIN_FILENO, &header, sizeof(header));
  if (status <= 0) return status;

  uint32_t frame_length = ntohl(header);
  if (frame_length > FRAME_LIMIT) return -1;
  status = read_all(STDIN_FILENO, payload, frame_length);
  if (status <= 0) return status;
  *length = frame_length;
  return 1;
}

static int termios_equal(const struct termios *left, const struct termios *right) {
  return left->c_iflag == right->c_iflag && left->c_oflag == right->c_oflag &&
         left->c_cflag == right->c_cflag && left->c_lflag == right->c_lflag &&
         memcmp(left->c_cc, right->c_cc, sizeof(left->c_cc)) == 0 &&
         cfgetispeed(left) == cfgetispeed(right) &&
         cfgetospeed(left) == cfgetospeed(right);
}

static int query_process(pid_t pid, struct kinfo_proc *process) {
  int query[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  while (1) {
    size_t size = sizeof(*process);
    memset(process, 0, sizeof(*process));
    if (sysctl(query, 4U, process, &size, NULL, 0U) == 0) {
      if (size == 0) return 0;
      return size == sizeof(*process) && process->kp_proc.p_pid == pid ? 1 : -1;
    }
    if (errno == EINTR) continue;
    return errno == ESRCH ? 0 : -1;
  }
}

static int read_process(pid_t pid, struct kinfo_proc *process) {
  return query_process(pid, process) == 1 ? 0 : -1;
}

static int initialize_owner_identity(void) {
  struct kinfo_proc owner;
  if (read_process(owner_pid, &owner) != 0 ||
      owner.kp_eproc.e_pgid != target_foreground_group ||
      owner.kp_eproc.e_tpgid != target_foreground_group) {
    return -1;
  }
  owner_start_time = owner.kp_proc.p_starttime;
  owner_identity_initialized = 1;

  if (completion_dir_fd >= 0) {
    struct kinfo_proc supervisor;
    if (supervisor_pid == owner_pid || owner.kp_eproc.e_ppid != supervisor_pid ||
        read_process(supervisor_pid, &supervisor) != 0 ||
        supervisor.kp_eproc.e_pgid != target_foreground_group ||
        supervisor.kp_eproc.e_tpgid != target_foreground_group) {
      return -1;
    }
    supervisor_start_time = supervisor.kp_proc.p_starttime;
    supervisor_identity_initialized = 1;
  }
  return 0;
}

static int foreground_owner_valid(void) {
  struct kinfo_proc owner;
  if (!owner_identity_initialized || read_process(owner_pid, &owner) != 0 ||
      owner.kp_proc.p_starttime.tv_sec != owner_start_time.tv_sec ||
      owner.kp_proc.p_starttime.tv_usec != owner_start_time.tv_usec ||
      owner.kp_eproc.e_pgid != target_foreground_group ||
      owner.kp_eproc.e_tpgid != target_foreground_group) {
    return 0;
  }
  if (completion_dir_fd < 0) return 1;

  struct kinfo_proc supervisor;
  return supervisor_identity_initialized && owner.kp_eproc.e_ppid == supervisor_pid &&
                 read_process(supervisor_pid, &supervisor) == 0 &&
                 supervisor.kp_proc.p_starttime.tv_sec == supervisor_start_time.tv_sec &&
                 supervisor.kp_proc.p_starttime.tv_usec == supervisor_start_time.tv_usec &&
                 supervisor.kp_eproc.e_pgid == target_foreground_group &&
                 supervisor.kp_eproc.e_tpgid == target_foreground_group
             ? 1
             : 0;
}

static int parse_identity(const char *argument, uint64_t *device, uint64_t *inode) {
  static const char prefix[] = "completion-identity=";
  if (strncmp(argument, prefix, sizeof(prefix) - 1U) != 0) return -1;
  const char *value = argument + sizeof(prefix) - 1U;
  char *separator = NULL;
  errno = 0;
  unsigned long long parsed_device = strtoull(value, &separator, 10);
  if (errno != 0 || separator == value || *separator != ':') return -1;
  char *end = NULL;
  errno = 0;
  unsigned long long parsed_inode = strtoull(separator + 1, &end, 10);
  if (errno != 0 || end == separator + 1 || *end != '\0') return -1;
  *device = (uint64_t)parsed_device;
  *inode = (uint64_t)parsed_inode;
  return 0;
}

static int configure_terminal_custody(const char *argument,
                                      const char *identity_argument) {
  static const char prefix[] = "completion=";
  if (strncmp(argument, prefix, sizeof(prefix) - 1U) != 0) return -1;
  const char *directory = argument + sizeof(prefix) - 1U;
  if (strcmp(directory, "-") == 0) return -1;
  if (directory[0] != '/') return -1;

  uint64_t expected_device;
  uint64_t expected_inode;
  if (parse_identity(identity_argument, &expected_device, &expected_inode) != 0)
    return -1;

  completion_dir_fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  if (completion_dir_fd < 0) return -1;
  struct stat directory_state;
  if (fstat(completion_dir_fd, &directory_state) != 0 ||
      !S_ISDIR(directory_state.st_mode) || directory_state.st_uid != geteuid() ||
      (directory_state.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)) != S_IRWXU ||
      (uint64_t)directory_state.st_dev != expected_device ||
      (uint64_t)directory_state.st_ino != expected_inode) {
    close(completion_dir_fd);
    completion_dir_fd = -1;
    return -1;
  }
  completion_registered = 1;
  return 0;
}

static int register_terminal_custody(void) {
  if (!completion_registered) return 0;
  struct stat available;
  if (fstatat(completion_dir_fd, "available", &available, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(available.st_mode) || available.st_uid != geteuid() ||
      (available.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)) != (S_IRUSR | S_IWUSR)) {
    return -1;
  }
  if (linkat(completion_dir_fd, "available", completion_dir_fd, "active", 0) != 0)
    return -1;
  if (unlinkat(completion_dir_fd, "available", 0) != 0 && errno != ENOENT) {
    (void)unlinkat(completion_dir_fd, "active", 0);
    return -1;
  }
  return 0;
}

static int complete_terminal_custody(void) {
  if (completion_registered) {
    if (unlinkat(completion_dir_fd, "active", 0) != 0 && errno != ENOENT) return -1;
    completion_registered = 0;
  }
  return 0;
}

static long long monotonic_milliseconds(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
  return (long long)now.tv_sec * 1000LL + now.tv_nsec / 1000000LL;
}

static int terminal_revoked(void);

static int discard_pending_input(void) {
  long long started = monotonic_milliseconds();
  if (started < 0 || tcflush(tty_fd, TCIFLUSH) != 0) return -1;
  long long quiet_deadline = started + DISCARD_QUIET_MS;

  while (1) {
    long long now = monotonic_milliseconds();
    if (now < 0) return -1;
    if (now >= quiet_deadline) return tcflush(tty_fd, TCIFLUSH);

    int timeout = (int)(quiet_deadline - now);
    struct pollfd descriptor = {.fd = tty_fd, .events = POLLIN | POLLHUP | POLLERR};
    int ready;
    do {
      ready = poll(&descriptor, 1, timeout);
    } while (ready < 0 && errno == EINTR);
    if (ready < 0) return -1;
    if (ready == 0) return tcflush(tty_fd, TCIFLUSH);
    if ((descriptor.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
      return terminal_revoked() ? 1 : -1;
    }
    if (tcflush(tty_fd, TCIFLUSH) != 0) return -1;
    quiet_deadline = monotonic_milliseconds() + DISCARD_QUIET_MS;
  }
}

static int terminal_revoked(void) {
  struct termios state;
  while (tcgetattr(tty_fd, &state) != 0) {
    if (errno == EINTR) continue;
    return errno == EIO || errno == ENXIO || errno == ENOTTY;
  }
  return 0;
}

static int complete_revoked_terminal(void) {
  while (complete_terminal_custody() != 0) {
    struct timespec retry = {.tv_sec = 0, .tv_nsec = 100000000L};
    (void)nanosleep(&retry, NULL);
  }
  return 0;
}

static int restore_saved_state(void) {
  while (1) {
    int discard_status = discard_pending_input();
    if (discard_status == 0 && tcsetattr(tty_fd, TCSAFLUSH, &saved_state) == 0) {
      struct termios actual;
      if (tcgetattr(tty_fd, &actual) == 0 && termios_equal(&actual, &saved_state)) {
        if (complete_terminal_custody() == 0) return 0;
      }
    }
    if (discard_status > 0 || terminal_revoked()) return complete_revoked_terminal();
    struct timespec retry = {.tv_sec = 0, .tv_nsec = 100000000L};
    (void)nanosleep(&retry, NULL);
  }
}

static int enter_protected_mode(void) {
  if (!foreground_owner_valid()) return -1;

  struct termios protected = saved_state;
  protected.c_lflag &= (tcflag_t)~(ECHO | ECHONL | ICANON | ISIG);
  protected.c_cc[VMIN] = 1;
  protected.c_cc[VTIME] = 0;

#ifdef ORCHARD_SECRET_TTY_TEST
  if (active_test_fault == TEST_FAULT_PARTIAL_PROTECT) {
    struct termios partial = saved_state;
    partial.c_lflag &= (tcflag_t)~ECHO;
    if (tcsetattr(tty_fd, TCSANOW, &partial) != 0) return -1;
    (void)restore_saved_state();
    return -1;
  }
#endif

  if (tcsetattr(tty_fd, TCSAFLUSH, &protected) != 0) {
    (void)restore_saved_state();
    return -1;
  }

  struct termios actual;
  if (tcgetattr(tty_fd, &actual) != 0 || !termios_equal(&actual, &protected)) {
    (void)restore_saved_state();
    return -1;
  }
  return 0;
}

static int is_special_character(unsigned char value, size_t index) {
  cc_t configured = saved_state.c_cc[index];
  return configured != _POSIX_VDISABLE && value == configured;
}

static void signal_handler(int signal_number) {
  int saved_errno = errno;
  unsigned char value = (unsigned char)signal_number;
  if (signal_write_fd >= 0) (void)write(signal_write_fd, &value, 1U);
  errno = saved_errno;
}

static int install_handler(int signal_number) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = signal_handler;
  sigemptyset(&action.sa_mask);
  action.sa_flags = 0;
  return sigaction(signal_number, &action, NULL);
}

static int ignore_signal(int signal_number) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = SIG_IGN;
  sigemptyset(&action.sa_mask);
  return sigaction(signal_number, &action, NULL);
}

static int configure_parent_signals(int signal_pipe[2]) {
  signal_write_fd = signal_pipe[1];
  return ignore_signal(SIGPIPE) || install_handler(SIGHUP) || install_handler(SIGINT) ||
                 install_handler(SIGTERM) || install_handler(SIGQUIT) ||
                 install_handler(SIGTSTP) || install_handler(SIGCONT) ||
                 ignore_signal(SIGTTIN) || ignore_signal(SIGTTOU)
             ? -1
             : 0;
}

static int make_signal_pipe_nonblocking(int signal_pipe[2]) {
  int flags = fcntl(signal_pipe[1], F_GETFL);
  return flags < 0 || fcntl(signal_pipe[1], F_SETFL, flags | O_NONBLOCK) != 0 ? -1 : 0;
}

static int configure_watchdog_signals(int signal_pipe[2]) {
  signal_write_fd = signal_pipe[1];
  if (ignore_signal(SIGPIPE) != 0) return -1;
  if (install_handler(SIGHUP) != 0 || install_handler(SIGINT) != 0 ||
      install_handler(SIGTERM) != 0 || install_handler(SIGQUIT) != 0 ||
      install_handler(SIGTSTP) != 0 || install_handler(SIGCONT) != 0) {
    return -1;
  }
  return 0;
}

static void quiesce_parent_reader(int control_fd) {
  if (send_byte(control_fd, CONTROL_QUIESCE) != 0) return;
  struct pollfd descriptor = {.fd = control_fd, .events = POLLIN | POLLHUP | POLLERR};
  int ready;
  do {
    ready = poll(&descriptor, 1, HANDSHAKE_TIMEOUT_MS);
  } while (ready < 0 && errno == EINTR);
  if (ready <= 0 || (descriptor.revents & POLLIN) == 0) return;
  unsigned char response;
  if (receive_byte(control_fd, &response) != 1 || response != CONTROL_QUIESCED) return;
}

static int watchdog_abort(int control_fd, int protected) {
  quiesce_parent_reader(control_fd);
  if (protected) {
    (void)restore_saved_state();
  } else {
    while (complete_terminal_custody() != 0) {
      struct timespec retry = {.tv_sec = 0, .tv_nsec = 100000000L};
      (void)nanosleep(&retry, NULL);
    }
  }
  (void)send_byte(control_fd, CONTROL_ABORT);
  return 1;
}

static int watchdog_loop(int control_fd, int signal_pipe[2]) {
  int protected = 0;
  int suspended = 0;

  close(STDIN_FILENO);
  close(STDERR_FILENO);

  if (configure_watchdog_signals(signal_pipe) != 0 || register_terminal_custody() != 0) {
    return 1;
  }
#ifdef ORCHARD_SECRET_TTY_TEST
  if (active_test_fault == TEST_FAULT_WATCHDOG_CUSTODY_HANDSHAKE) {
    static const char marker[] = "__ORCHARD_TEST_CUSTODY_REGISTERED__";
    (void)write_all(tty_fd, marker, sizeof(marker) - 1U);
    (void)raise(SIGSTOP);
  }
  if (active_test_fault == TEST_FAULT_MARKER_PRE_READY_KILL) {
    (void)kill(getppid(), SIGKILL);
  }
#endif
  if (send_byte(control_fd, CONTROL_READY) != 0) {
    while (complete_terminal_custody() != 0) {
      struct timespec retry = {.tv_sec = 0, .tv_nsec = 100000000L};
      (void)nanosleep(&retry, NULL);
    }
    return 1;
  }

  while (1) {
    struct pollfd descriptors[2] = {
        {.fd = control_fd, .events = POLLIN | POLLHUP},
        {.fd = signal_pipe[0], .events = POLLIN}};
    int ready = poll(descriptors, 2, 100);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) break;
    if (ready == 0) {
      if (!foreground_owner_valid()) {
        return watchdog_abort(control_fd, protected);
      }
      continue;
    }

    if ((descriptors[1].revents & POLLIN) != 0) {
      unsigned char signal_number;
      if (read(signal_pipe[0], &signal_number, 1U) != 1) break;

      if (signal_number == SIGCONT && suspended) {
        (void)send_byte(control_fd, CONTROL_ABORT);
        return 1;
      }
      if (signal_number == SIGTSTP && protected) {
        quiesce_parent_reader(control_fd);
        if (restore_saved_state() != 0) {
          (void)send_byte(control_fd, CONTROL_FAILED);
          return 1;
        }
        protected = 0;
        suspended = 1;
        if (kill(-target_foreground_group, SIGSTOP) != 0) {
          return 1;
        }
        continue;
      }
      if (signal_number == SIGHUP || signal_number == SIGINT ||
          signal_number == SIGTERM || signal_number == SIGQUIT) {
        return watchdog_abort(control_fd, protected);
      }
    }

    if ((descriptors[0].revents & (POLLIN | POLLHUP)) != 0) {
      unsigned char command;
      int status = receive_byte(control_fd, &command);
      if (status <= 0) break;

      if (command == CONTROL_ENTER) {
        if (enter_protected_mode() == 0) {
          protected = 1;
          if (send_byte(control_fd, CONTROL_PROTECTED) != 0) break;
        } else {
          (void)send_byte(control_fd, CONTROL_FAILED);
          return 1;
        }
      } else if (command == CONTROL_DONE) {
        if (protected && restore_saved_state() != 0) {
          (void)send_byte(control_fd, CONTROL_FAILED);
          return 1;
        }
        protected = 0;
        (void)send_byte(control_fd, CONTROL_RESTORED);
        return 0;
      } else {
        break;
      }
    }
  }

  if (protected) {
    (void)restore_saved_state();
  } else {
    while (complete_terminal_custody() != 0) {
      struct timespec retry = {.tv_sec = 0, .tv_nsec = 100000000L};
      (void)nanosleep(&retry, NULL);
    }
  }
  (void)send_byte(control_fd, CONTROL_ABORT);
  return 1;
}

static int wait_for_control(int control_fd, unsigned char expected) {
  struct pollfd descriptors[2] = {
      {.fd = control_fd, .events = POLLIN | POLLHUP | POLLERR},
      {.fd = STDIN_FILENO, .events = POLLIN | POLLHUP | POLLERR | POLLNVAL}};
  int ready;
  do {
    ready = poll(descriptors, 2, HANDSHAKE_TIMEOUT_MS);
  } while (ready < 0 && errno == EINTR);
  if (ready <= 0 || descriptors[1].revents != 0 ||
      (descriptors[0].revents & POLLIN) == 0) {
    return -1;
  }

  unsigned char response;
  int status = receive_byte(control_fd, &response);
  return status == 1 && response == expected ? 0 : -1;
}

static int reap_watchdog(pid_t watchdog, int terminate_first, int *status) {
  if (terminate_first) (void)kill(watchdog, SIGKILL);

  for (int attempt = 0; attempt < 100; attempt++) {
    pid_t waited = waitpid(watchdog, status, WNOHANG);
    if (waited == watchdog) return 0;
    if (waited < 0 && errno != EINTR) return -1;
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000L};
    (void)nanosleep(&delay, NULL);
  }

  if (!terminate_first) (void)kill(watchdog, SIGKILL);
  for (int attempt = 0; attempt < 100; attempt++) {
    pid_t waited = waitpid(watchdog, status, WNOHANG);
    if (waited == watchdog) return 0;
    if (waited < 0 && errno != EINTR) return -1;
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000L};
    (void)nanosleep(&delay, NULL);
  }
  return -1;
}

static int wait_for_child(pid_t child, int *status) {
  while (1) {
    pid_t waited = waitpid(child, status, 0);
    if (waited == child) return 0;
    if (waited < 0 && errno == EINTR) continue;
    return -1;
  }
}

static int process_identity_state(pid_t process, const struct timeval *started) {
#ifdef ORCHARD_SECRET_TTY_TEST
  static int identity_failure_injected = 0;
  if (active_test_fault == TEST_FAULT_RESTORER_IDENTITY_RETRY &&
      !identity_failure_injected) {
    identity_failure_injected = 1;
    return -1;
  }
#endif
  struct kinfo_proc state;
  int status = query_process(process, &state);
  if (status <= 0) return status;
  return state.kp_proc.p_starttime.tv_sec == started->tv_sec &&
                 state.kp_proc.p_starttime.tv_usec == started->tv_usec
             ? 1
             : 0;
}

static void stop_known_watchdog(pid_t watchdog, const struct timeval *started) {
  while (1) {
    int identity = process_identity_state(watchdog, started);
    if (identity == 0) return;
    if (identity > 0) (void)kill(watchdog, SIGKILL);
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000L};
    (void)nanosleep(&delay, NULL);
  }
}

static int configure_emergency_signals(void) {
#ifdef ORCHARD_SECRET_TTY_TEST
  if (active_test_fault == TEST_FAULT_RESTORER_SIGNAL_SETUP) {
    struct stat marker;
    while (fstatat(completion_dir_fd, "active", &marker, AT_SYMLINK_NOFOLLOW) != 0) {
      struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000L};
      (void)nanosleep(&delay, NULL);
    }
    char notice[160];
    int notice_length = snprintf(
        notice, sizeof(notice),
        "__ORCHARD_TEST_SIGNAL_PARENT__:%d\n"
        "__ORCHARD_TEST_SIGNAL_EMERGENCY__:%d\n"
        "__ORCHARD_TEST_SIGNAL_WATCHDOG__:",
        getppid(), getpid());
    if (notice_length > 0 && (size_t)notice_length < sizeof(notice))
      (void)write_all(tty_fd, notice, (size_t)notice_length);
    struct timespec marker_delay = {.tv_sec = 0, .tv_nsec = 50000000L};
    (void)nanosleep(&marker_delay, NULL);
    notice_length = snprintf(notice, sizeof(notice), "%d\n", watchdog_pid);
    if (notice_length > 0 && (size_t)notice_length < sizeof(notice))
      (void)write_all(tty_fd, notice, (size_t)notice_length);
    return -1;
  }
#endif
  return ignore_signal(SIGHUP) || ignore_signal(SIGINT) || ignore_signal(SIGTERM) ||
                 ignore_signal(SIGQUIT) || ignore_signal(SIGTSTP) ||
                 ignore_signal(SIGCONT) || ignore_signal(SIGPIPE) ||
                 ignore_signal(SIGTTIN) || ignore_signal(SIGTTOU)
             ? -1
             : 0;
}

static int emergency_restorer_loop(int control_fd, int watchdog_control_fd,
                                   int signal_fd, pid_t watchdog,
                                   const struct timeval *watchdog_started) {
  close(watchdog_control_fd);
  signal_write_fd = -1;
  close(signal_fd);
  close(STDIN_FILENO);
  close(STDERR_FILENO);

  if (configure_emergency_signals() != 0) {
    close(control_fd);
    return 1;
  }
  if (send_byte(control_fd, CONTROL_READY) != 0) {
    stop_known_watchdog(watchdog, watchdog_started);
    return restore_saved_state() == 0 ? 0 : 1;
  }

  unsigned char request = 0;
  int received = receive_byte(control_fd, &request);
  if (received == 1 && request == CONTROL_ABORT) {
    int acknowledged = send_byte(control_fd, CONTROL_ABORT) == 0;
    close(control_fd);
    return acknowledged ? 0 : 1;
  }

  int requested = received == 1 && request == CONTROL_DONE;
  stop_known_watchdog(watchdog, watchdog_started);
  int restored = restore_saved_state() == 0;
  if (requested && restored) (void)send_byte(control_fd, CONTROL_RESTORED);
  close(control_fd);
  return restored ? 0 : 1;
}

static pid_t start_emergency_restorer(int *parent_control, int watchdog_control_fd,
                                      int signal_fd, pid_t watchdog) {
  struct kinfo_proc watchdog_state;
  if (read_process(watchdog, &watchdog_state) != 0 ||
      watchdog_state.kp_eproc.e_ppid != getpid()) {
    return -1;
  }
  struct timeval watchdog_started = watchdog_state.kp_proc.p_starttime;

  int control[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, control) != 0) return -1;

  pid_t restorer = fork();
  if (restorer < 0) {
    close(control[0]);
    close(control[1]);
    return -1;
  }
  if (restorer == 0) {
    close(control[0]);
    _exit(emergency_restorer_loop(control[1], watchdog_control_fd, signal_fd,
                                  watchdog, &watchdog_started));
  }

  close(control[1]);
  unsigned char response = 0;
  if (receive_byte(control[0], &response) != 1 || response != CONTROL_READY) {
    close(control[0]);
    int status;
    (void)wait_for_child(restorer, &status);
    return -1;
  }
  *parent_control = control[0];
  return restorer;
}

static int dismiss_emergency_restorer(int control_fd, pid_t restorer) {
  int acknowledged = send_byte(control_fd, CONTROL_ABORT) == 0;
  unsigned char response = 0;
  if (acknowledged)
    acknowledged = receive_byte(control_fd, &response) == 1 && response == CONTROL_ABORT;
  close(control_fd);

  int status;
  int reaped = wait_for_child(restorer, &status) == 0;
  return acknowledged && reaped && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0
                                                                                : -1;
}

static int finish_emergency_restorer(int control_fd, pid_t restorer) {
  int acknowledged = send_byte(control_fd, CONTROL_DONE) == 0;
  unsigned char response = 0;
  if (acknowledged)
    acknowledged = receive_byte(control_fd, &response) == 1 &&
                   response == CONTROL_RESTORED;
  close(control_fd);

  int status;
  int reaped = wait_for_child(restorer, &status) == 0;
  if (acknowledged && reaped && WIFEXITED(status) && WEXITSTATUS(status) == 0) return 0;
  return restore_saved_state();
}

static int restore_after_failed_handshake(int control_fd, pid_t watchdog,
                                          int restorer_control,
                                          pid_t restorer) {
  close(control_fd);
  int watchdog_status;
  (void)reap_watchdog(watchdog, 1, &watchdog_status);
#ifdef ORCHARD_SECRET_TTY_TEST
  if (active_test_fault == TEST_FAULT_RESTORER_PARENT_KILL) {
    char marker[64];
    int marker_length = snprintf(marker, sizeof(marker),
                                 "__ORCHARD_TEST_RESTORER_ARMED__:%d\n", getpid());
    if (marker_length > 0 && (size_t)marker_length < sizeof(marker))
      (void)write_all(tty_fd, marker, (size_t)marker_length);
    (void)raise(SIGSTOP);
  }
#endif
  return finish_emergency_restorer(restorer_control, restorer);
}

static int wait_for_restoration(int control_fd) {
  while (1) {
    unsigned char response;
    int received = receive_byte(control_fd, &response);
    if (received != 1) return -1;
    if (response == CONTROL_RESTORED) return 0;
    if (response == CONTROL_QUIESCE) {
      if (send_byte(control_fd, CONTROL_QUIESCED) != 0) return -1;
      continue;
    }
    return -1;
  }
}

static int finish_watchdog(int control_fd, pid_t watchdog, int protected) {
  int acknowledged = send_byte(control_fd, CONTROL_DONE) == 0 &&
                     wait_for_restoration(control_fd) == 0;
  close(control_fd);
  int status;
  int reaped = reap_watchdog(watchdog, !acknowledged, &status) == 0;
  if (acknowledged && reaped && WIFEXITED(status) && WEXITSTATUS(status) == 0) return 0;
  return protected && restore_saved_state() == 0 ? 0 : -1;
}

static int finish_watchdog_abort(int control_fd, pid_t watchdog, int protected) {
  unsigned char response = 0;
  int received = receive_byte(control_fd, &response);
  if (received == 1 && response == CONTROL_QUIESCE) {
    if (send_byte(control_fd, CONTROL_QUIESCED) == 0)
      received = receive_byte(control_fd, &response);
    else
      received = -1;
  }
  int acknowledged = received == 1 && response == CONTROL_ABORT;
  close(control_fd);

  int status;
  int reaped = reap_watchdog(watchdog, !acknowledged, &status) == 0;
  if (acknowledged && reaped && WIFEXITED(status) && WEXITSTATUS(status) == 1) return 0;
  return protected && restore_saved_state() == 0 ? 0 : -1;
}

static int wait_for_protocol_or_abort(int control_fd, int wait_for_tty) {
  struct pollfd descriptors[3] = {
      {.fd = wait_for_tty ? tty_fd : STDIN_FILENO, .events = POLLIN | POLLHUP},
      {.fd = control_fd, .events = POLLIN | POLLHUP | POLLERR | POLLNVAL},
      {.fd = wait_for_tty ? STDIN_FILENO : -1,
       .events = POLLIN | POLLHUP | POLLERR | POLLNVAL}};

  while (1) {
    int ready = poll(descriptors, 3, -1);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) return -1;
    if (descriptors[1].revents != 0) return 1;
    if (wait_for_tty && descriptors[2].revents != 0) return 2;
    if ((descriptors[0].revents & (POLLIN | POLLHUP)) != 0) return 0;
  }
}

static int read_tty_line(int control_fd, unsigned char *value, size_t *length) {
  size_t used = 0;

  while (1) {
    int ready = wait_for_protocol_or_abort(control_fd, 1);
    if (ready == 2) return -6;
    if (ready != 0) return ready > 0 ? -2 : -1;

    unsigned char value_byte;
    ssize_t count = read(tty_fd, &value_byte, 1U);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) return -1;
    if (count == 0) {
      *length = used;
      return used == 0 ? 0 : 1;
    }
    if (value_byte == '\n' || value_byte == '\r') {
      *length = used;
      return 1;
    }
    if (is_special_character(value_byte, VINTR)) return -3;
    if (is_special_character(value_byte, VQUIT)) return -4;
    if (is_special_character(value_byte, VSUSP)) return -5;
    if (is_special_character(value_byte, VEOF)) {
      *length = used;
      return used == 0 ? 0 : 1;
    }
    if (is_special_character(value_byte, VERASE)) {
      if (used > 0) {
        size_t erased = 1U;
        if ((saved_state.c_iflag & IUTF8) != 0) {
          size_t start = used - 1U;
          while (start > 0U && used - start < 4U &&
                 (value[start] & 0xC0U) == 0x80U) {
            start--;
          }

          unsigned char lead = value[start];
          size_t expected = lead >= 0xC2U && lead <= 0xDFU   ? 2U
                            : lead >= 0xE0U && lead <= 0xEFU ? 3U
                            : lead >= 0xF0U && lead <= 0xF4U ? 4U
                                                            : 0U;
          size_t actual = used - start;
          int valid = expected == actual;
          if (valid && expected == 3U) {
            valid = !(lead == 0xE0U && value[start + 1U] < 0xA0U) &&
                    !(lead == 0xEDU && value[start + 1U] >= 0xA0U);
          }
          if (valid && expected == 4U) {
            valid = !(lead == 0xF0U && value[start + 1U] < 0x90U) &&
                    !(lead == 0xF4U && value[start + 1U] > 0x8FU);
          }
          if (valid) erased = expected;
        }
        used -= erased;
      }
      continue;
    }
    if (is_special_character(value_byte, VKILL)) {
      used = 0;
      continue;
    }
    if (used >= FRAME_LIMIT - 6U) return -1;
    value[used++] = value_byte;
  }
}

static int handle_read(int control_fd, const unsigned char *frame, size_t frame_length) {
  static const char prefix[] = "READ:";
  if (frame_length < sizeof(prefix) - 1U ||
      memcmp(frame, prefix, sizeof(prefix) - 1U) != 0) {
    return -1;
  }

  const unsigned char *prompt = frame + sizeof(prefix) - 1U;
  size_t prompt_length = frame_length - (sizeof(prefix) - 1U);
  if (write_all(tty_fd, prompt, prompt_length) != 0) return -1;

#ifdef ORCHARD_SECRET_TTY_TEST
  int injected_signal = 0;
  if (active_test_fault == TEST_FAULT_SIGNAL_INT) injected_signal = SIGINT;
  if (active_test_fault == TEST_FAULT_SIGNAL_HUP) injected_signal = SIGHUP;
  if (active_test_fault == TEST_FAULT_SIGNAL_TERM) injected_signal = SIGTERM;
  if (active_test_fault == TEST_FAULT_SIGNAL_KILL) injected_signal = SIGKILL;
  if (active_test_fault == TEST_FAULT_WATCHDOG_READ) (void)kill(watchdog_pid, SIGKILL);
  if (injected_signal != 0) {
    if (injected_signal == SIGKILL)
      (void)kill(getpid(), injected_signal);
    else
      (void)kill(-getpgrp(), injected_signal);
    return -1;
  }
#endif

  unsigned char response[FRAME_LIMIT];
  memcpy(response, "VALUE:", 6U);
  size_t value_length = 0;
  int status = read_tty_line(control_fd, response + 6U, &value_length);
  if (status <= -2) return status;
  if (write_all(tty_fd, "\n", 1U) != 0) return -1;
  if (status == 0) return send_frame("EOF", 3U);
  if (status < 0) return send_frame("READ_ERROR", 10U);
  return send_frame(response, value_length + 6U);
}

static int run_protocol(int control_fd, pid_t watchdog) {
  unsigned char frame[FRAME_LIMIT];
  int protected = 1;

  while (1) {
    int ready = wait_for_protocol_or_abort(control_fd, 0);
    if (ready > 0) {
      if (finish_watchdog_abort(control_fd, watchdog, protected) == 0)
        (void)send_frame("ABORTED", 7U);
      return -1;
    }
    if (ready < 0) break;

    size_t frame_length = 0;
    int status = receive_frame(frame, &frame_length);
    if (status <= 0) break;

    if (frame_length == 7U && memcmp(frame, "RESTORE", 7U) == 0) {
      if (finish_watchdog(control_fd, watchdog, protected) == 0) {
        protected = 0;
        return send_frame("RESTORED", 8U);
      }
      (void)send_frame("RESTORE_ERROR", 13U);
      return -1;
    }

    status = handle_read(control_fd, frame, frame_length);
    if (status == -6) {
      (void)send_byte(control_fd, CONTROL_QUIESCED);
      (void)finish_watchdog_abort(control_fd, watchdog, protected);
      return -1;
    }
    if (status == -2) {
      if (finish_watchdog_abort(control_fd, watchdog, protected) == 0)
        (void)send_frame("ABORTED", 7U);
      return -1;
    }
    if (status <= -3) {
      int terminal_signal = 0;
      if (status == -5) terminal_signal = SIGSTOP;

      if (finish_watchdog(control_fd, watchdog, protected) != 0) return -1;
      protected = 0;
      if (terminal_signal != 0 && foreground_owner_valid())
        (void)kill(-target_foreground_group, terminal_signal);
      (void)send_frame("ABORTED", 7U);
      return -1;
    }
    if (status != 0) break;
  }

  if (finish_watchdog(control_fd, watchdog, protected) == 0) return 0;
  return -1;
}

int main(int argc, char **argv) {
#ifdef ORCHARD_SECRET_TTY_TEST
  if (argc != 7 && argc != 8) return 64;
  if (argc == 8) {
    if (strcmp(argv[7], "partial-protect") == 0)
      active_test_fault = TEST_FAULT_PARTIAL_PROTECT;
    else if (strcmp(argv[7], "post-protect") == 0)
      active_test_fault = TEST_FAULT_POST_PROTECT;
    else if (strcmp(argv[7], "signal-int") == 0)
      active_test_fault = TEST_FAULT_SIGNAL_INT;
    else if (strcmp(argv[7], "signal-hup") == 0)
      active_test_fault = TEST_FAULT_SIGNAL_HUP;
    else if (strcmp(argv[7], "signal-term") == 0)
      active_test_fault = TEST_FAULT_SIGNAL_TERM;
    else if (strcmp(argv[7], "signal-kill") == 0)
      active_test_fault = TEST_FAULT_SIGNAL_KILL;
    else if (strcmp(argv[7], "marker-pre-ready-kill") == 0)
      active_test_fault = TEST_FAULT_MARKER_PRE_READY_KILL;
    else if (strcmp(argv[7], "watchdog-handshake") == 0)
      active_test_fault = TEST_FAULT_WATCHDOG_HANDSHAKE;
    else if (strcmp(argv[7], "watchdog-custody-handshake") == 0)
      active_test_fault = TEST_FAULT_WATCHDOG_CUSTODY_HANDSHAKE;
    else if (strcmp(argv[7], "watchdog-protected-handshake") == 0)
      active_test_fault = TEST_FAULT_WATCHDOG_PROTECTED_HANDSHAKE;
    else if (strcmp(argv[7], "restorer-parent-kill") == 0)
      active_test_fault = TEST_FAULT_RESTORER_PARENT_KILL;
    else if (strcmp(argv[7], "restorer-pre-teardown-kill") == 0)
      active_test_fault = TEST_FAULT_RESTORER_PRE_TEARDOWN_KILL;
    else if (strcmp(argv[7], "restorer-identity-retry") == 0)
      active_test_fault = TEST_FAULT_RESTORER_IDENTITY_RETRY;
    else if (strcmp(argv[7], "restorer-signal-setup") == 0)
      active_test_fault = TEST_FAULT_RESTORER_SIGNAL_SETUP;
    else if (strcmp(argv[7], "watchdog-idle") == 0)
      active_test_fault = TEST_FAULT_WATCHDOG_IDLE;
    else if (strcmp(argv[7], "watchdog-read") == 0)
      active_test_fault = TEST_FAULT_WATCHDOG_READ;
    else
      return 64;
  }
#else
  if (argc != 7) return 64;
#endif

  static const char supervisor_prefix[] = "supervisor=";
  if (strncmp(argv[4], supervisor_prefix, sizeof(supervisor_prefix) - 1U) != 0)
    return 64;
  char *supervisor_end = NULL;
  errno = 0;
  long supervisor_value = strtol(argv[4] + sizeof(supervisor_prefix) - 1U,
                                 &supervisor_end, 10);
  if (errno != 0 || supervisor_end == argv[4] + sizeof(supervisor_prefix) - 1U ||
      *supervisor_end != '\0' || supervisor_value <= 1 || supervisor_value > INT_MAX) {
    return 64;
  }
  supervisor_pid = (pid_t)supervisor_value;

  char *group_end = NULL;
  errno = 0;
  long group_value = strtol(argv[2], &group_end, 10);
  if (errno != 0 || group_end == argv[2] || *group_end != '\0' || group_value <= 1 ||
      group_value > INT_MAX) {
    return 64;
  }
  pid_t foreground_group = (pid_t)group_value;
  target_foreground_group = foreground_group;

  char *owner_end = NULL;
  errno = 0;
  long owner_value = strtol(argv[3], &owner_end, 10);
  if (errno != 0 || owner_end == argv[3] || *owner_end != '\0' || owner_value <= 1 ||
      owner_value > INT_MAX) {
    return 64;
  }
  owner_pid = (pid_t)owner_value;
  if (configure_terminal_custody(argv[5], argv[6]) != 0) {
    (void)send_frame("SETUP_ERROR", 11U);
    return 1;
  }
  if (initialize_owner_identity() != 0) {
    (void)send_frame("SETUP_ERROR", 11U);
    if (completion_dir_fd >= 0) close(completion_dir_fd);
    return 1;
  }

  tty_fd = open(argv[1], O_RDWR | O_NOCTTY);
  if (tty_fd < 0 || !isatty(tty_fd)) {
    (void)send_frame("SETUP_ERROR", 11U);
    if (tty_fd >= 0) close(tty_fd);
    return 1;
  }
  if (tcgetattr(tty_fd, &saved_state) != 0) {
    (void)send_frame("SETUP_ERROR", 11U);
    close(tty_fd);
    return 1;
  }

  int control[2];
  int signal_pipe[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, control) != 0 || pipe(signal_pipe) != 0 ||
      make_signal_pipe_nonblocking(signal_pipe) != 0 ||
      configure_parent_signals(signal_pipe) != 0) {
    (void)send_frame("SETUP_ERROR", 11U);
    close(tty_fd);
    return 1;
  }
  pid_t watchdog = fork();
  if (watchdog < 0) {
    (void)send_frame("SETUP_ERROR", 11U);
    close(tty_fd);
    return 1;
  }
  if (watchdog == 0) {
    close(control[0]);
#ifdef ORCHARD_SECRET_TTY_TEST
    if (active_test_fault == TEST_FAULT_WATCHDOG_HANDSHAKE) (void)raise(SIGSTOP);
#endif
    _exit(watchdog_loop(control[1], signal_pipe));
  }
  watchdog_pid = watchdog;

  close(control[1]);
  close(signal_pipe[0]);
  int restorer_control = -1;
  pid_t restorer = start_emergency_restorer(&restorer_control, control[0],
                                            signal_pipe[1], watchdog);
  if (restorer < 0) {
    close(control[0]);
    (void)kill(watchdog, SIGCONT);
    int watchdog_status;
    (void)wait_for_child(watchdog, &watchdog_status);
    (void)send_frame("SETUP_ERROR", 11U);
    close(signal_pipe[1]);
    close(tty_fd);
    return 1;
  }
  if (wait_for_control(control[0], CONTROL_READY) != 0) {
    (void)restore_after_failed_handshake(control[0], watchdog, restorer_control,
                                         restorer);
    (void)send_frame("SETUP_ERROR", 11U);
    close(signal_pipe[1]);
    close(tty_fd);
    return 1;
  }

  int handshake_failed = 0;
  if (send_frame("PREPARED", 8U) != 0) {
    handshake_failed = 1;
  } else {
    unsigned char frame[FRAME_LIMIT];
    size_t frame_length = 0;
    int received = receive_frame(frame, &frame_length);
    if (received != 1 || frame_length != 5U || memcmp(frame, "ENTER", 5U) != 0 ||
        send_byte(control[0], CONTROL_ENTER) != 0) {
      handshake_failed = 1;
    }
#ifdef ORCHARD_SECRET_TTY_TEST
    else if (active_test_fault == TEST_FAULT_RESTORER_PRE_TEARDOWN_KILL ||
             active_test_fault == TEST_FAULT_RESTORER_IDENTITY_RETRY) {
      char marker[72];
      const char *prefix =
          active_test_fault == TEST_FAULT_RESTORER_IDENTITY_RETRY
              ? "__ORCHARD_TEST_RESTORER_IDENTITY__"
              : "__ORCHARD_TEST_RESTORER_PRE_TEARDOWN__";
      if (active_test_fault == TEST_FAULT_RESTORER_IDENTITY_RETRY)
        (void)kill(watchdog, SIGSTOP);
      int marker_length = snprintf(marker, sizeof(marker), "%s:%d\n", prefix, getpid());
      if (marker_length > 0 && (size_t)marker_length < sizeof(marker))
        (void)write_all(tty_fd, marker, (size_t)marker_length);
      (void)raise(SIGSTOP);
      handshake_failed = 1;
    }
#endif
    else if (wait_for_control(control[0], CONTROL_PROTECTED) != 0) {
      handshake_failed = 1;
    }
#ifdef ORCHARD_SECRET_TTY_TEST
    else if (active_test_fault == TEST_FAULT_WATCHDOG_PROTECTED_HANDSHAKE ||
             active_test_fault == TEST_FAULT_RESTORER_PARENT_KILL) {
      static const char marker[] = "__ORCHARD_TEST_PROTECTED__";
      if (active_test_fault == TEST_FAULT_WATCHDOG_PROTECTED_HANDSHAKE)
        (void)write_all(tty_fd, marker, sizeof(marker) - 1U);
      (void)kill(watchdog, SIGSTOP);
      handshake_failed = 1;
    }
#endif
  }
  if (handshake_failed) {
    (void)restore_after_failed_handshake(control[0], watchdog, restorer_control,
                                         restorer);
    (void)send_frame("SETUP_ERROR", 11U);
    close(signal_pipe[1]);
    close(tty_fd);
    return 1;
  }
  if (dismiss_emergency_restorer(restorer_control, restorer) != 0) {
    (void)finish_watchdog(control[0], watchdog, 1);
    (void)send_frame("SETUP_ERROR", 11U);
    close(signal_pipe[1]);
    close(tty_fd);
    return 1;
  }
#ifdef ORCHARD_SECRET_TTY_TEST
  if (active_test_fault == TEST_FAULT_POST_PROTECT) {
    (void)finish_watchdog(control[0], watchdog, 1);
    (void)send_frame("SETUP_ERROR", 11U);
    close(signal_pipe[1]);
    close(tty_fd);
    return 1;
  }
#endif
  if (send_frame("READY", 5U) != 0) {
    (void)finish_watchdog(control[0], watchdog, 1);
    close(signal_pipe[1]);
    close(tty_fd);
    return 1;
  }
#ifdef ORCHARD_SECRET_TTY_TEST
  if (active_test_fault == TEST_FAULT_WATCHDOG_IDLE) (void)kill(watchdog, SIGKILL);
#endif

  int status = run_protocol(control[0], watchdog);
  close(signal_pipe[1]);
  close(tty_fd);
  return status == 0 ? 0 : 1;
}
