#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

#define CAPTURE_LIMIT 65536
#define BACKPRESSURE_LIMIT 262144
#define PROCESS_LIMIT 2048
#define TRACKED_PROCESS_LIMIT 32
#define TIMEOUT_MS 15000
// Paced writers sleep between every write, and macOS timer coalescing routinely
// stretches each 50ms interval several times past its nominal length, so a
// 220-write paste takes far longer than its nominal 11s. Budget the writer wait
// independently of the ordinary harness I/O timeout.
#define WRITER_TIMEOUT_MS 120000

struct capture {
  char bytes[CAPTURE_LIMIT];
  size_t length;
};

struct process_entry {
  pid_t pid;
  char command[512];
};

struct tracked_processes {
  pid_t values[TRACKED_PROCESS_LIMIT];
  size_t length;
};

enum process_state { PROCESS_ABSENT, PROCESS_LIVE, PROCESS_ZOMBIE };

static const char *scenario_name;
static int fragmented_record_release_fd = -1;
static int read_once(int master, struct capture *capture);

static void fail(const char *stage) {
  fprintf(stderr, "console PTY failure: %s: %s\n", scenario_name, stage);
  exit(1);
}

static long long now_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) fail("clock");
  return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static const char *find_bytes(const struct capture *capture, const char *needle) {
  size_t needle_length = strlen(needle);
  if (needle_length == 0 || needle_length > capture->length) return NULL;

  for (size_t index = 0; index + needle_length <= capture->length; index++) {
    if (memcmp(capture->bytes + index, needle, needle_length) == 0) {
      return capture->bytes + index;
    }
  }
  return NULL;
}

static int contains(const struct capture *capture, const char *needle) {
  return find_bytes(capture, needle) != NULL;
}

static int complete_record(const struct capture *capture, const char *marker) {
  const char *cursor = find_bytes(capture, marker);
  if (cursor == NULL) return 0;
  cursor += strlen(marker);

  while (cursor < capture->bytes + capture->length) {
    if (*cursor == '\r' || *cursor == '\n') return 1;
    cursor++;
  }
  return 0;
}

static void release_fragmented_record_suffix(const struct capture *capture,
                                             const char *marker) {
  if (fragmented_record_release_fd < 0 || find_bytes(capture, marker) == NULL ||
      complete_record(capture, marker))
    return;

  while (write(fragmented_record_release_fd, "x", 1U) < 0) {
    if (errno != EINTR) fail("record-self-test-release");
  }
  close(fragmented_record_release_fd);
  fragmented_record_release_fd = -1;
}

static long record_number(const struct capture *capture, const char *marker,
                          const char *stage) {
  const char *cursor = find_bytes(capture, marker);
  if (cursor == NULL || !complete_record(capture, marker)) fail(stage);
  cursor += strlen(marker);
  if (cursor == capture->bytes + capture->length || *cursor < '0' || *cursor > '9')
    fail(stage);

  long value = 0;
  while (cursor < capture->bytes + capture->length && *cursor >= '0' &&
         *cursor <= '9') {
    int digit = *cursor - '0';
    if (value > (LONG_MAX - digit) / 10L) fail(stage);
    value = value * 10L + digit;
    cursor++;
  }
  if (cursor == capture->bytes + capture->length ||
      (*cursor != '\r' && *cursor != '\n'))
    fail(stage);
  return value;
}

static int process_exit_status(const struct capture *capture) {
  long status = record_number(capture, "__ORCHARD_PROCESS_EXIT__:",
                              "process-exit-record");
  if (status > 255L) fail("process-exit-record");
  return (int)status;
}

static void marked_path(const struct capture *capture, const char *marker,
                        char *output, size_t output_size) {
  const char *cursor = find_bytes(capture, marker);
  if (cursor == NULL || !complete_record(capture, marker)) fail("path-marker");
  cursor += strlen(marker);

  size_t used = 0;
  while (cursor < capture->bytes + capture->length && *cursor != '\r' &&
         *cursor != '\n') {
    if (used + 1U >= output_size) fail("path-marker-size");
    output[used++] = *cursor++;
  }
  if (used == 0) fail("path-marker");
  output[used] = '\0';
}

static struct tracked_processes guard_processes(const char *slave_name) {
  struct process_entry entries[PROCESS_LIMIT];
  size_t count = 0;
  FILE *processes = popen("/bin/ps -ww -axo pid=,command=", "r");
  if (processes == NULL) fail("process-scan");

  char line[256];
  while (count < PROCESS_LIMIT && fgets(line, sizeof(line), processes) != NULL) {
    int pid = 0;
    char command[512];
    if (sscanf(line, "%d %511[^\n]", &pid, command) == 2) {
      entries[count].pid = (pid_t)pid;
      memcpy(entries[count].command, command, strlen(command) + 1);
      count++;
    }
  }
  if (pclose(processes) != 0) fail("process-scan");

  struct tracked_processes tracked = {0};
  for (size_t index = 0; index < count; index++) {
    if (strstr(entries[index].command, "orchard-secret-tty") != NULL &&
        strstr(entries[index].command, slave_name) != NULL) {
      if (tracked.length == TRACKED_PROCESS_LIMIT) fail("tracked-process-limit");
      tracked.values[tracked.length++] = entries[index].pid;
    }
  }
  if (tracked.length < 2) fail("guard-processes-not-found");
  return tracked;
}

static enum process_state inspect_process(pid_t pid) {
  char command[64];
  int length = snprintf(command, sizeof(command), "/bin/ps -o stat= -p %d", pid);
  if (length < 0 || (size_t)length >= sizeof(command)) fail("process-status-command");

  FILE *status = popen(command, "r");
  if (status == NULL) fail("process-status");
  char state[16] = {0};
  int found = fgets(state, sizeof(state), status) != NULL;
  if (pclose(status) != 0 && found) fail("process-status");
  if (!found) return PROCESS_ABSENT;
  return state[0] == 'Z' ? PROCESS_ZOMBIE : PROCESS_LIVE;
}

static int process_running(pid_t pid) {
  return inspect_process(pid) == PROCESS_LIVE;
}

static void wait_for_processes_exit(const struct tracked_processes *tracked) {
  long long deadline = now_ms() + TIMEOUT_MS;

  while (now_ms() < deadline) {
    int alive = 0;
    for (size_t index = 0; index < tracked->length; index++) {
      if (process_running(tracked->values[index])) alive = 1;
    }
    if (!alive) return;
    usleep(10000);
  }
  fail("secret-tty-process-survived-owner-exit");
}

static void wait_for_process_exit(pid_t pid, const char *stage) {
  long long deadline = now_ms() + TIMEOUT_MS;
  while (now_ms() < deadline) {
    if (!process_running(pid)) return;
    usleep(10000);
  }
  fail(stage);
}

static void wait_for_process_absence(pid_t pid, const char *stage) {
  long long deadline = now_ms() + TIMEOUT_MS;
  while (now_ms() < deadline) {
    if (inspect_process(pid) == PROCESS_ABSENT) return;
    usleep(10000);
  }
  fail(stage);
}

static void wait_for_process_absence_while_reading(
    int master, struct capture *capture, pid_t pid, pid_t wrapper,
    const char *stage) {
  long long deadline = now_ms() + TIMEOUT_MS;

  while (now_ms() < deadline) {
    enum process_state state = inspect_process(pid);
    int lifecycle_marker = complete_record(capture, "__ORCHARD_CLI_REAPED__:") ||
                           complete_record(capture, "__ORCHARD_PROCESS_EXIT__:");
    if (lifecycle_marker) {
      if (state != PROCESS_ABSENT) fail("lifecycle-marker-before-cli-absence");
      return;
    }
    if (state == PROCESS_ABSENT) return;
    if (!process_running(wrapper)) fail("wrapper-exited-before-cli");

    struct pollfd descriptor = {.fd = master, .events = POLLIN | POLLHUP};
    int ready = poll(&descriptor, 1, 10);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) fail("poll");
    if (ready > 0) (void)read_once(master, capture);
  }
  fail(stage);
}

static int wait_for_child_exit(pid_t child) {
  long long deadline = now_ms() + TIMEOUT_MS;
  while (now_ms() < deadline) {
    int status;
    pid_t waited = waitpid(child, &status, WNOHANG);
    if (waited == child) return status;
    if (waited < 0 && errno != EINTR) fail("child-exit-wait");
    usleep(10000);
  }
  fail("child-exit-timeout");
  return 0;
}

static int read_once(int master, struct capture *capture) {
  if (capture->length == CAPTURE_LIMIT) fail("capture-limit");

  ssize_t count = read(master, capture->bytes + capture->length,
                       CAPTURE_LIMIT - capture->length);
  if (count > 0) {
    capture->length += (size_t)count;
    return 1;
  }
  if (count == 0) return 0;
  if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) return 1;
  if (errno == EIO) return 0;
  fail("read");
  return 0;
}

static void read_until(int master, struct capture *capture, const char *needle,
                       const char *stage) {
  long long deadline = now_ms() + TIMEOUT_MS;
  int process_exit = strcmp(needle, "__ORCHARD_PROCESS_EXIT__:") == 0;

  while (!(process_exit ? complete_record(capture, needle) : contains(capture, needle))) {
    if (process_exit) release_fragmented_record_suffix(capture, needle);
    if (complete_record(capture, "__ORCHARD_PROCESS_EXIT__:") &&
        strcmp(stage, "queue-status") != 0 && strcmp(stage, "owner-exit") != 0) {
      if (contains(capture, "could not disable terminal echo")) fail("helper-setup-error");
      if (contains(capture, "interactive terminal unavailable")) fail("terminal-unavailable");
      if (contains(capture, "must not be blank")) fail("blank-rejected-without-result");
      if (contains(capture, "Console password: ")) fail("continued-to-password-prompt");
      if (contains(capture, "__ORCHARD_PTY_RESULT__:")) fail("result-before-process-exit");
      fail("command-exited-before-expected-output");
    }
    int remaining = (int)(deadline - now_ms());
    if (remaining <= 0) fail(stage);

    struct pollfd descriptor = {.fd = master, .events = POLLIN | POLLHUP};
    int ready = poll(&descriptor, 1, remaining);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) fail("poll");
    if (ready == 0) fail(stage);
    if (!read_once(master, capture) &&
        !(process_exit ? complete_record(capture, needle) : contains(capture, needle)))
      fail(stage);
  }
}

static void read_until_expected_setup_exit(int master, struct capture *capture) {
  long long deadline = now_ms() + TIMEOUT_MS;

  while (!complete_record(capture, "__ORCHARD_PROCESS_EXIT__:")) {
    release_fragmented_record_suffix(capture, "__ORCHARD_PROCESS_EXIT__:");
    int remaining = (int)(deadline - now_ms());
    if (remaining <= 0) fail("restorer-signal-setup-exit");

    struct pollfd descriptor = {.fd = master, .events = POLLIN | POLLHUP};
    int ready = poll(&descriptor, 1, remaining);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) fail("poll");
    if (ready == 0) fail("restorer-signal-setup-exit");
    if (!read_once(master, capture) &&
        !complete_record(capture, "__ORCHARD_PROCESS_EXIT__:"))
      fail("restorer-signal-setup-exit");
  }

  if (!contains(capture, "could not disable terminal echo"))
    fail("restorer-signal-setup-error-missing");
}

static void read_until_complete_record(int master, struct capture *capture,
                                       const char *marker, const char *stage) {
  long long deadline = now_ms() + TIMEOUT_MS;

  while (!complete_record(capture, marker)) {
    release_fragmented_record_suffix(capture, marker);
    if (complete_record(capture, "__ORCHARD_PROCESS_EXIT__:") &&
        strcmp(stage, "queue-status") != 0)
      fail(stage);
    int remaining = (int)(deadline - now_ms());
    if (remaining <= 0) fail(stage);

    struct pollfd descriptor = {.fd = master, .events = POLLIN | POLLHUP};
    int ready = poll(&descriptor, 1, remaining);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) fail("poll");
    if (ready == 0) fail(stage);
    if (!read_once(master, capture) && !complete_record(capture, marker)) fail(stage);
  }
}

static long read_record_number(int master, struct capture *capture,
                               const char *marker, const char *stage) {
  read_until_complete_record(master, capture, marker, stage);
  return record_number(capture, marker, stage);
}

static int read_status_record(int master, struct capture *capture,
                              const char *marker, const char *stage) {
  long status = read_record_number(master, capture, marker, stage);
  if (status > 255L) fail(stage);
  return (int)status;
}

static pid_t read_marked_pid(int master, struct capture *capture,
                             const char *marker) {
  long value = read_record_number(master, capture, marker, marker);
  if (value <= 0 || value > INT_MAX) fail("pid-marker");
  return (pid_t)value;
}

static void read_marked_path(int master, struct capture *capture,
                             const char *marker, char *output,
                             size_t output_size) {
  read_until_complete_record(master, capture, marker, "path-marker");
  marked_path(capture, marker, output, output_size);
}

static void read_until_while_process_running(int master, struct capture *capture,
                                             const char *needle, const char *stage,
                                             pid_t process) {
  long long deadline = now_ms() + TIMEOUT_MS;

  while (!contains(capture, needle)) {
    if (!process_running(process)) fail("wrapper-exited-before-cli");
    if (complete_record(capture, "__ORCHARD_CLI_REAPED__:"))
      fail("cli-reaped-before-cli-exit");
    if (complete_record(capture, "__ORCHARD_PROCESS_EXIT__:"))
      fail("process-exit-before-cli");
    int remaining = (int)(deadline - now_ms());
    if (remaining <= 0) fail(stage);

    struct pollfd descriptor = {.fd = master, .events = POLLIN | POLLHUP};
    int ready = poll(&descriptor, 1, remaining > 10 ? 10 : remaining);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) fail("poll");
    if (ready > 0 && !read_once(master, capture) && !contains(capture, needle))
      fail(stage);
  }
  if (!process_running(process)) fail("wrapper-exited-before-cli");
  if (complete_record(capture, "__ORCHARD_CLI_REAPED__:"))
    fail("cli-reaped-before-cli-exit");
  if (complete_record(capture, "__ORCHARD_PROCESS_EXIT__:"))
    fail("process-exit-before-cli");
}

static void write_all(int master, const void *bytes, size_t length) {
  const char *cursor = bytes;
  while (length > 0) {
    ssize_t count = write(master, cursor, length);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) fail("write");
    cursor += count;
    length -= (size_t)count;
  }
}

static pid_t spawn_backpressure_writer(int master, unsigned char first,
                                       const char *secret) {
  pid_t writer = fork();
  if (writer < 0) fail("paste-writer-fork");
  if (writer != 0) return writer;

  char *paste = malloc(BACKPRESSURE_LIMIT);
  if (paste == NULL) _exit(2);
  paste[0] = (char)first;
  size_t used = 1U;
  size_t secret_length = strlen(secret);
  while (used + secret_length + 1U <= BACKPRESSURE_LIMIT) {
    memcpy(paste + used, secret, secret_length);
    used += secret_length;
    paste[used++] = '\n';
  }
  write_all(master, paste, used);
  free(paste);
  _exit(0);
}

static pid_t spawn_paced_writer_for(int master, unsigned char first,
                                    const char *secret, int writes) {
  pid_t writer = fork();
  if (writer < 0) fail("paced-writer-fork");
  if (writer != 0) return writer;

  write_all(master, &first, 1U);
  for (int index = 0; index < writes; index++) {
    write_all(master, secret, strlen(secret));
    write_all(master, "\n", 1U);
    usleep(50000);
  }
  _exit(0);
}

static pid_t spawn_paced_writer(int master, unsigned char first,
                                const char *secret) {
  return spawn_paced_writer_for(master, first, secret, 60);
}

static pid_t spawn_started_paced_writer(int master, unsigned char first,
                                        const char *secret) {
  int started[2];
  if (pipe(started) != 0) fail("paced-writer-pipe");
  pid_t writer = fork();
  if (writer < 0) fail("paced-writer-fork");
  if (writer == 0) {
    close(started[0]);
    write_all(master, &first, 1U);
    write_all(started[1], "x", 1U);
    close(started[1]);
    for (int index = 0; index < 60; index++) {
      write_all(master, secret, strlen(secret));
      write_all(master, "\n", 1U);
      usleep(50000);
    }
    _exit(0);
  }

  close(started[1]);
  char marker;
  if (read(started[0], &marker, 1U) != 1) fail("paced-writer-start");
  close(started[0]);
  return writer;
}

static void wait_for_writer(pid_t writer) {
  long long deadline = now_ms() + WRITER_TIMEOUT_MS;
  while (now_ms() < deadline) {
    int status;
    pid_t waited = waitpid(writer, &status, WNOHANG);
    if (waited == writer) {
      if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) fail("paste-writer-status");
      return;
    }
    if (waited < 0 && errno != EINTR) fail("paste-writer-wait");
    usleep(10000);
  }
  fail("paste-writer-timeout");
}

static void drain_available(int master, struct capture *capture) {
  while (1) {
    struct pollfd descriptor = {.fd = master, .events = POLLIN | POLLHUP};
    int ready = poll(&descriptor, 1, 0);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) fail("poll");
    if (ready == 0 || (descriptor.revents & POLLIN) == 0) return;
    if (!read_once(master, capture)) return;
  }
}

static int termios_equal(const struct termios *left, const struct termios *right) {
  return left->c_iflag == right->c_iflag && left->c_oflag == right->c_oflag &&
         left->c_cflag == right->c_cflag && left->c_lflag == right->c_lflag &&
         memcmp(left->c_cc, right->c_cc, sizeof(left->c_cc)) == 0 &&
         cfgetispeed(left) == cfgetispeed(right) &&
         cfgetospeed(left) == cfgetospeed(right);
}

static int echo_disabled(int slave) {
  struct termios state;
  if (tcgetattr(slave, &state) != 0) fail("get-live-state");
  return (state.c_lflag & ECHO) == 0;
}

static void wait_for_state(int slave, const struct termios *expected) {
  long long deadline = now_ms() + TIMEOUT_MS;
  struct termios actual = {0};

  while (now_ms() < deadline) {
    if (tcgetattr(slave, &actual) == 0 && termios_equal(&actual, expected)) return;
    usleep(10000);
  }
  fprintf(stderr,
          "termios mismatch: iflag=%lx/%lx oflag=%lx/%lx cflag=%lx/%lx "
          "lflag=%lx/%lx\n",
          (unsigned long)actual.c_iflag, (unsigned long)expected->c_iflag,
          (unsigned long)actual.c_oflag, (unsigned long)expected->c_oflag,
          (unsigned long)actual.c_cflag, (unsigned long)expected->c_cflag,
          (unsigned long)actual.c_lflag, (unsigned long)expected->c_lflag);
  fail("terminal-state-not-restored");
}

static void wait_for_state_while_reading(int master, int slave,
                                         const struct termios *expected,
                                         struct capture *capture) {
  long long deadline = now_ms() + TIMEOUT_MS;
  struct termios actual;

  while (now_ms() < deadline) {
    if (tcgetattr(slave, &actual) == 0 && termios_equal(&actual, expected)) return;

    struct pollfd descriptor = {.fd = master, .events = POLLIN | POLLHUP};
    int ready = poll(&descriptor, 1, 10);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) fail("poll");
    if (ready > 0 && (descriptor.revents & POLLIN) != 0) {
      (void)read_once(master, capture);
    }
  }
  fail("terminal-state-not-restored");
}

static pid_t spawn_child(int *master, char *slave_name,
                         struct termios *initial, char **command) {
  struct winsize window = {.ws_row = 24, .ws_col = 80};
  pid_t child = forkpty(master, slave_name, initial, &window);
  if (child < 0) fail("forkpty");
  if (child != 0) return child;

  size_t command_count = 0;
  while (command[command_count] != NULL) command_count++;

  char **shell_args = calloc(command_count + 5, sizeof(char *));
  if (shell_args == NULL) _exit(126);
  shell_args[0] = "sh";
  shell_args[1] = "-c";
  int foreground_wrapper = strncmp(scenario_name, "wrapper-", 8U) == 0 ||
                           strcmp(scenario_name, "guard-pre-ready-death") == 0 ||
                           strcmp(scenario_name, "terminal-close") == 0;
  if (foreground_wrapper) {
    shell_args[2] =
        "ORCHARD_CLI_FOREGROUND_SUPERVISOR_PID=$$; "
        "export ORCHARD_CLI_FOREGROUND_SUPERVISOR_PID; "
        "unset ORCHARD_CLI_COMPLETION_DIR ORCHARD_CLI_COMPLETION_IDENTITY; "
        "trap ':' INT QUIT; "
        "if \"$@\"; then status=0; else status=$?; fi; "
        "printf '__ORCHARD_PROCESS_EXIT__:%s\\n' \"$status\"; "
        "IFS= read -r resumed || resumed=; "
        "if [ \"$resumed\" = '__ORCHARD_QUEUE_SENTINEL__' ]; then "
        "printf '__ORCHARD_RESUMED_CLEAN__\\n'; "
        "else printf '__ORCHARD_RESUMED_DIRTY__\\n'; fi; sleep 30";
  } else if (strcmp(scenario_name, "unwrapped") == 0) {
    shell_args[2] =
        "ORCHARD_CLI_FOREGROUND_SUPERVISOR_PID=$$; "
        "export ORCHARD_CLI_FOREGROUND_SUPERVISOR_PID; "
        "unset ORCHARD_CLI_COMPLETION_DIR ORCHARD_CLI_COMPLETION_IDENTITY; "
        "\"$@\" & command_pid=$!; "
        "if wait \"$command_pid\"; then status=0; else status=$?; fi; "
        "printf '__ORCHARD_PROCESS_EXIT__:%s\\n' \"$status\"; "
        "IFS= read -r resumed || resumed=; "
        "if [ \"$resumed\" = '__ORCHARD_QUEUE_SENTINEL__' ]; then "
        "printf '__ORCHARD_RESUMED_CLEAN__\\n'; "
        "else printf '__ORCHARD_RESUMED_DIRTY__\\n'; fi; sleep 30";
  } else {
    shell_args[2] =
      "ORCHARD_CLI_FOREGROUND_SUPERVISOR_PID=$$; "
      "export ORCHARD_CLI_FOREGROUND_SUPERVISOR_PID; "
      "ORCHARD_CLI_COMPLETION_DIR=$(/usr/bin/mktemp -d /private/tmp/orchard-pty.XXXXXX) "
      "|| exit 126; "
      "/bin/chmod 0700 \"$ORCHARD_CLI_COMPLETION_DIR\" || exit 126; "
      "export ORCHARD_CLI_COMPLETION_DIR; "
      "ORCHARD_CLI_COMPLETION_IDENTITY=$(/usr/bin/stat -f '%d:%i' "
      "\"$ORCHARD_CLI_COMPLETION_DIR\") || exit 126; "
      "export ORCHARD_CLI_COMPLETION_IDENTITY; "
      "(umask 077 && : > \"$ORCHARD_CLI_COMPLETION_DIR/available\") || exit 126; "
      "\"$@\" & command_pid=$!; "
      "if wait \"$command_pid\"; then status=0; else status=$?; fi; "
      "/bin/rm -f \"$ORCHARD_CLI_COMPLETION_DIR/available\" || exit 126; "
      "while [ -e \"$ORCHARD_CLI_COMPLETION_DIR/active\" ]; do /bin/sleep 0.01; done; "
      "/bin/rmdir \"$ORCHARD_CLI_COMPLETION_DIR\" || exit 126; "
      "printf '__ORCHARD_PROCESS_EXIT__:%s\\n' \"$status\"; "
      "IFS= read -r resumed || resumed=; "
      "if [ \"$resumed\" = '__ORCHARD_QUEUE_SENTINEL__' ]; then "
      "printf '__ORCHARD_RESUMED_CLEAN__\\n'; "
      "else printf '__ORCHARD_RESUMED_DIRTY__\\n'; fi; sleep 30";
  }
  shell_args[3] = "orchard-pty-owner";
  for (size_t index = 0; index < command_count; index++) {
    shell_args[index + 4] = command[index];
  }

  execv("/bin/sh", shell_args);
  _exit(127);
}

static void finish_child(pid_t session, int master, struct capture *capture) {
  const char *sentinel = "__ORCHARD_QUEUE_SENTINEL__\n";
  read_until(master, capture, "__ORCHARD_PROCESS_EXIT__:", "owner-exit");
  write_all(master, sentinel, strlen(sentinel));
  read_until_complete_record(master, capture, "__ORCHARD_RESUMED_", "queue-status");
  if (contains(capture, "__ORCHARD_RESUMED_DIRTY__")) fail("queued-input-survived");
  if (!contains(capture, "__ORCHARD_RESUMED_CLEAN__")) fail("queue-clean-marker-missing");
  kill(session, SIGKILL);
  if (waitpid(session, NULL, 0) < 0) fail("waitpid");
}

static void generated_value(char *output, size_t length, const char *prefix) {
  snprintf(output, length, "%s-%08x-%08x", prefix, arc4random(), arc4random());
}

static void run_pasted(int master, int slave, pid_t child,
                       const struct termios *initial, int expect_success,
                       int delay_ms, const char *expected_output) {
  struct capture capture = {0};
  char username[48];
  char password[48];
  char confirmation[48];
  char paste[128];
  generated_value(username, sizeof(username), "operator");
  generated_value(password, sizeof(password), "credential");
  generated_value(confirmation, sizeof(confirmation), "confirmation");

  read_until(master, &capture, "Console username: ", "username-prompt");
  int protected_before_username = echo_disabled(slave);
  if (delay_ms > 0) {
    usleep((useconds_t)delay_ms * 1000);
    drain_available(master, &capture);
    if (contains(&capture, "__ORCHARD_PTY_RESULT__:")) fail("credential-read-timed-out");
  }
  int paste_length = snprintf(paste, sizeof(paste), "%s\n%s\n", username, password);
  if (paste_length < 0 || (size_t)paste_length >= sizeof(paste)) fail("paste-size");
  write_all(master, paste, (size_t)paste_length);

  read_until(master, &capture, "Console password: ", "password-prompt");
  int protected_at_password = echo_disabled(slave);
  read_until(master, &capture, "Confirm console password: ", "confirmation-prompt");
  int protected_at_confirmation = echo_disabled(slave);

  const char *final_value = expect_success ? password : confirmation;
  write_all(master, final_value, strlen(final_value));
  write_all(master, "\n", 1);

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "process-exit");
  int successful_result = process_exit_status(&capture) == 0;
  wait_for_state(slave, initial);

  finish_child(child, master, &capture);

  if (!protected_before_username) fail("echo-enabled-before-username-prompt");
  if (!protected_at_password) fail("echo-enabled-at-password-prompt");
  if (!protected_at_confirmation) fail("echo-enabled-at-confirmation-prompt");
  if (contains(&capture, password) || contains(&capture, confirmation)) fail("secret-captured");
  if (expected_output != NULL && !contains(&capture, expected_output))
    fail("expected-output-missing");
  if (expect_success && !successful_result) fail("unexpected-exit");
  if (!expect_success && successful_result) fail("unexpected-success");
}

static void run_wrapper_late_int(int master, int slave, pid_t child,
                                 const struct termios *initial) {
  struct capture capture = {0};
  char username[48];
  char password[48];
  char confirmation[48];
  char paste[128];
  generated_value(username, sizeof(username), "operator");
  generated_value(password, sizeof(password), "credential");
  generated_value(confirmation, sizeof(confirmation), "confirmation");

  read_until(master, &capture, "Console username: ", "late-int-username");
  pid_t wrapper = read_marked_pid(master, &capture, "__ORCHARD_WRAPPER_PID__:");
  int paste_length = snprintf(paste, sizeof(paste), "%s\n%s\n", username, password);
  if (paste_length < 0 || (size_t)paste_length >= sizeof(paste)) fail("paste-size");
  write_all(master, paste, (size_t)paste_length);
  read_until(master, &capture, "Console password: ", "late-int-password");
  read_until(master, &capture, "Confirm console password: ",
             "late-int-confirmation");
  write_all(master, confirmation, strlen(confirmation));
  write_all(master, "\n", 1U);

  read_until(master, &capture, "__ORCHARD_PRE_EXIT__", "late-int-barrier");
  write_all(master, &initial->c_cc[VINTR], 1U);
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "late-int-exit");
  if (process_exit_status(&capture) != 130) fail("late-int-status");
  wait_for_process_absence(wrapper, "late-int-wrapper-survived");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
  if (contains(&capture, password) || contains(&capture, confirmation))
    fail("late-int-secret-captured");
}

static void run_wrapper_post_wait_int(int master, int slave, pid_t child,
                                      const struct termios *initial,
                                      const char *barrier,
                                      int check_cli_status) {
  struct capture capture = {0};
  char username[48];
  char password[48];
  char confirmation[48];
  char paste[128];
  generated_value(username, sizeof(username), "operator");
  generated_value(password, sizeof(password), "credential");
  generated_value(confirmation, sizeof(confirmation), "confirmation");

  read_until(master, &capture, "Console username: ", "post-wait-username");
  int paste_length = snprintf(paste, sizeof(paste), "%s\n%s\n", username, password);
  if (paste_length < 0 || (size_t)paste_length >= sizeof(paste)) fail("paste-size");
  write_all(master, paste, (size_t)paste_length);
  read_until(master, &capture, "Console password: ", "post-wait-password");
  read_until(master, &capture, "Confirm console password: ",
             "post-wait-confirmation");
  write_all(master, confirmation, strlen(confirmation));
  write_all(master, "\n", 1U);

  read_until(master, &capture, barrier, "post-wait-barrier");
  write_all(master, &initial->c_cc[VINTR], 1U);
  if (!check_cli_status &&
      read_status_record(master, &capture, "__ORCHARD_GUARD_POST_SIGNAL__:",
                         "post-wait-guard-signal") != 130)
    fail("post-wait-guard-signal-status");
  if (check_cli_status &&
      read_status_record(master, &capture, "__ORCHARD_CLI_REAPED__:",
                         "post-wait-cli-reaped") != 1)
    fail("post-wait-cli-status");
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "post-wait-exit");
  int exit_status = process_exit_status(&capture);
  if (exit_status != 130) {
    fprintf(stderr, "post-wait exit status: %d\n", exit_status);
    fail("post-wait-exit-status");
  }
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
  if (contains(&capture, password) || contains(&capture, confirmation))
    fail("post-wait-secret-captured");
}

static void run_utf8_erase(int master, int slave, pid_t child,
                           const struct termios *initial) {
  struct capture capture = {0};
  char password[48];
  generated_value(password, sizeof(password), "credential");

  read_until(master, &capture, "Console username: ", "username-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-username-prompt");
  const unsigned char username[] = "operator-\xC3\xA9";
  write_all(master, username, sizeof(username) - 1U);
  write_all(master, &initial->c_cc[VERASE], 1U);
  write_all(master, "x\n", 2U);

  read_until(master, &capture, "Console password: ", "password-prompt");
  write_all(master, password, strlen(password));
  write_all(master, "\n", 1U);
  read_until(master, &capture, "Confirm console password: ", "confirmation-prompt");
  write_all(master, password, strlen(password));
  write_all(master, "\n", 1U);

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "process-exit");
  if (process_exit_status(&capture) != 0) fail("unexpected-exit-status");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
  if (contains(&capture, password)) fail("secret-captured");
}

static void run_eof(int master, int slave, pid_t child,
                    const struct termios *initial) {
  struct capture capture = {0};
  char username[48];
  generated_value(username, sizeof(username), "operator");

  read_until(master, &capture, "Console username: ", "username-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-username-prompt");
  write_all(master, username, strlen(username));
  write_all(master, "\n", 1);
  read_until(master, &capture, "Console password: ", "password-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-at-password-prompt");
  write_all(master, "\004", 1);

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "process-exit");
  if (process_exit_status(&capture) != 1) fail("unexpected-exit-status");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
}

static void run_exception(int master, int slave, pid_t child,
                          const struct termios *initial) {
  struct capture capture = {0};
  char input[48];
  generated_value(input, sizeof(input), "input");

  read_until(master, &capture, "Console username: ", "exception-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-at-exception-prompt");
  write_all(master, input, strlen(input));
  write_all(master, "\n", 1);

  if (read_status_record(master, &capture, "__ORCHARD_PTY_RESULT__:",
                         "exception-result") != 70)
    fail("exception-result-status");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
  if (contains(&capture, input)) fail("exception-input-captured");
}

static void run_setup_failure(int master, int slave, pid_t child,
                              const struct termios *initial) {
  struct capture capture = {0};
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "setup-exit");
  if (process_exit_status(&capture) == 0) fail("setup-succeeded");
  if (contains(&capture, "Console username: ") ||
      contains(&capture, "Console password: ")) {
    fail("prompt-rendered-before-setup");
  }
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
}

static void run_protected_setup_paced(int master, int slave, pid_t child,
                                      const struct termios *initial) {
  struct capture capture = {0};
  char secret[48];
  generated_value(secret, sizeof(secret), "credential");

  read_until(master, &capture, "__ORCHARD_TEST_PROTECTED__", "protected-setup-state");
  if (!echo_disabled(slave)) fail("protected-setup-echo");
  pid_t writer = spawn_paced_writer_for(master, 'x', secret, 220);
  wait_for_writer(writer);

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "setup-exit");
  if (process_exit_status(&capture) == 0) fail("setup-succeeded");
  if (contains(&capture, "Console username: ") ||
      contains(&capture, "Console password: ")) {
    fail("prompt-rendered-before-setup");
  }
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
  if (contains(&capture, secret)) fail("secret-captured");
}

static void run_restorer_parent_kill(int master, int slave, pid_t child,
                                     const struct termios *initial) {
  struct capture capture = {0};
  char secret[48];
  generated_value(secret, sizeof(secret), "credential");

  read_until(master, &capture, "__ORCHARD_TEST_RESTORER_ARMED__:",
             "restorer-armed");
  if (!echo_disabled(slave)) fail("restorer-parent-echo");
  pid_t helper = read_marked_pid(master, &capture, "__ORCHARD_TEST_RESTORER_ARMED__:");
  struct tracked_processes tracked = guard_processes(ttyname(slave));
  pid_t writer = spawn_paced_writer_for(master, 'x', secret, 220);
  if (kill(helper, SIGKILL) != 0) fail("restorer-parent-kill");

  wait_for_writer(writer);
  if (!echo_disabled(slave)) fail("restorer-returned-before-writer-complete");
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "restorer-parent-exit");
  if (process_exit_status(&capture) == 0)
    fail("restorer-parent-succeeded");
  wait_for_state(slave, initial);
  wait_for_processes_exit(&tracked);
  finish_child(child, master, &capture);
  if (contains(&capture, secret)) fail("restorer-parent-secret-captured");
}

static void run_restorer_pre_teardown_kill(int master, int slave, pid_t child,
                                           const struct termios *initial) {
  struct capture capture = {0};

  read_until(master, &capture, "__ORCHARD_TEST_RESTORER_PRE_TEARDOWN__:",
             "restorer-pre-teardown-armed");
  pid_t helper = read_marked_pid(
      master, &capture, "__ORCHARD_TEST_RESTORER_PRE_TEARDOWN__:");
  struct tracked_processes tracked = guard_processes(ttyname(slave));
  if (kill(helper, SIGKILL) != 0) fail("restorer-pre-teardown-kill");

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:",
             "restorer-pre-teardown-exit");
  if (process_exit_status(&capture) == 0)
    fail("restorer-pre-teardown-succeeded");
  wait_for_state(slave, initial);
  wait_for_processes_exit(&tracked);
  finish_child(child, master, &capture);
}

static void run_restorer_identity_retry(int master, int slave, pid_t child,
                                        const struct termios *initial) {
  struct capture capture = {0};

  read_until(master, &capture, "__ORCHARD_TEST_RESTORER_IDENTITY__:",
             "restorer-identity-armed");
  pid_t helper =
      read_marked_pid(master, &capture, "__ORCHARD_TEST_RESTORER_IDENTITY__:");
  struct tracked_processes tracked = guard_processes(ttyname(slave));
  if (kill(helper, SIGKILL) != 0) fail("restorer-identity-parent-kill");

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:",
             "restorer-identity-exit");
  if (process_exit_status(&capture) == 0)
    fail("restorer-identity-succeeded");
  wait_for_state(slave, initial);
  wait_for_processes_exit(&tracked);
  finish_child(child, master, &capture);
}

static void run_watchdog_custody_handshake(int master, int slave, pid_t child,
                                           const struct termios *initial) {
  struct capture capture = {0};

  read_until(master, &capture, "__ORCHARD_TEST_CUSTODY_REGISTERED__",
             "custody-handshake-registered");
  struct tracked_processes tracked = guard_processes(ttyname(slave));
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:",
             "custody-handshake-exit");
  if (process_exit_status(&capture) == 0)
    fail("custody-handshake-succeeded");
  wait_for_state(slave, initial);
  wait_for_processes_exit(&tracked);
  finish_child(child, master, &capture);
}

static void run_restorer_signal_setup(int master, int slave, pid_t child,
                                      const struct termios *initial) {
  struct capture capture = {0};

  read_until_complete_record(master, &capture, "__ORCHARD_TEST_SIGNAL_WATCHDOG__:",
                             "restorer-signal-setup-marker");
  pid_t parent = read_marked_pid(master, &capture, "__ORCHARD_TEST_SIGNAL_PARENT__:");
  pid_t emergency =
      read_marked_pid(master, &capture, "__ORCHARD_TEST_SIGNAL_EMERGENCY__:");
  pid_t watchdog =
      read_marked_pid(master, &capture, "__ORCHARD_TEST_SIGNAL_WATCHDOG__:");
  read_until_expected_setup_exit(master, &capture);
  if (process_exit_status(&capture) == 0)
    fail("restorer-signal-setup-succeeded");
  wait_for_state(slave, initial);
  wait_for_process_absence(parent, "restorer-signal-parent-survived");
  wait_for_process_absence(emergency, "restorer-signal-emergency-survived");
  wait_for_process_absence(watchdog, "restorer-signal-watchdog-survived");
  finish_child(child, master, &capture);
}

static void run_helper_signal(int master, int slave, pid_t child,
                              const struct termios *initial) {
  struct capture capture = {0};
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "helper-signal-exit");
  if (process_exit_status(&capture) == 0) fail("helper-signal-succeeded");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
}

static void run_port_owner_exit(int master, int slave, pid_t child,
                                const struct termios *initial) {
  struct capture capture = {0};
  read_until(master, &capture, "__ORCHARD_PORT_OWNER_READY__", "port-owner-ready");
  struct tracked_processes tracked = guard_processes(ttyname(slave));
  read_until(master, &capture, "__ORCHARD_PORT_OWNER_DIED__", "port-owner-died");
  wait_for_state(slave, initial);
  wait_for_processes_exit(&tracked);
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "port-owner-exit");
  if (process_exit_status(&capture) == 0) fail("port-owner-succeeded");
  finish_child(child, master, &capture);
}

static void run_invalid_username_paste(int master, int slave, pid_t child,
                                       const struct termios *initial) {
  struct capture capture = {0};
  char password[48];
  char confirmation[48];
  char paste[160];
  generated_value(password, sizeof(password), "credential");
  generated_value(confirmation, sizeof(confirmation), "confirmation");

  read_until(master, &capture, "Console username: ", "username-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-username-prompt");

  int paste_length = snprintf(paste, sizeof(paste), "\n%s\n%s\n",
                              password, confirmation);
  if (paste_length < 0 || (size_t)paste_length >= sizeof(paste)) fail("paste-size");
  write_all(master, paste, (size_t)paste_length);

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "process-exit");
  if (process_exit_status(&capture) != 1) fail("unexpected-exit-status");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);

  if (contains(&capture, password) || contains(&capture, confirmation)) {
    fail("secret-captured");
  }
}

static void run_invalid_username_backpressure(int master, int slave, pid_t child,
                                              const struct termios *initial) {
  struct capture capture = {0};
  char secret[48];
  generated_value(secret, sizeof(secret), "credential");

  read_until(master, &capture, "Console username: ", "username-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-username-prompt");
  pid_t writer = spawn_backpressure_writer(master, '\n', secret);

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "process-exit");
  if (process_exit_status(&capture) != 1) fail("unexpected-exit-status");
  wait_for_writer(writer);
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
  if (contains(&capture, secret)) fail("secret-captured");
}

static void run_invalid_username_paced(int master, int slave, pid_t child,
                                       const struct termios *initial) {
  struct capture capture = {0};
  char secret[48];
  generated_value(secret, sizeof(secret), "credential");

  read_until(master, &capture, "Console username: ", "username-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-username-prompt");
  pid_t writer = spawn_paced_writer(master, '\n', secret);

  wait_for_writer(writer);
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "process-exit");
  if (process_exit_status(&capture) != 1) fail("unexpected-exit-status");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
  if (contains(&capture, secret)) fail("secret-captured");
}

static void run_owner_exit(int master, int slave, pid_t child,
                           const struct termios *initial) {
  struct capture capture = {0};
  read_until(master, &capture, "Console username: ", "owner-exit-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-owner-exit");

  pid_t owner = read_marked_pid(master, &capture, "__ORCHARD_OWNER_PID__:");
  struct tracked_processes tracked = guard_processes(ttyname(slave));
  if (kill(owner, SIGKILL) != 0) fail("owner-kill");

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "owner-exit");
  wait_for_state(slave, initial);
  wait_for_processes_exit(&tracked);
  finish_child(child, master, &capture);
}

static void run_owner_exit_paced(int master, int slave, pid_t child,
                                  const struct termios *initial) {
  struct capture capture = {0};
  char tail[48];
  generated_value(tail, sizeof(tail), "paste-tail");

  read_until(master, &capture, "Console username: ", "owner-exit-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-owner-exit");
  pid_t owner = read_marked_pid(master, &capture, "__ORCHARD_OWNER_PID__:");
  struct tracked_processes tracked = guard_processes(ttyname(slave));
  pid_t writer = spawn_started_paced_writer(master, 'x', tail);
  if (kill(owner, SIGKILL) != 0) fail("owner-kill");

  wait_for_writer(writer);
  if (!echo_disabled(slave)) fail("owner-exit-restored-before-writer-complete");
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "owner-exit");
  wait_for_state(slave, initial);
  wait_for_processes_exit(&tracked);
  finish_child(child, master, &capture);
  const char *tail_capture = find_bytes(&capture, tail);
  if (tail_capture != NULL) {
    const char *process_exit = find_bytes(&capture, "__ORCHARD_PROCESS_EXIT__:");
    fail(tail_capture < process_exit ? "owner-exit-tail-before-exit"
                                     : "owner-exit-tail-after-exit");
  }
}

static void run_wrapper_signal_paced(int master, int slave, pid_t child,
                                     const struct termios *initial,
                                     int signal_number,
                                     int expected_status) {
  struct capture capture = {0};
  char tail[48];
  generated_value(tail, sizeof(tail), "paste-tail");

  read_until(master, &capture, "Console username: ", "wrapper-term-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-wrapper-term");
  pid_t wrapper = read_marked_pid(master, &capture, "__ORCHARD_WRAPPER_PID__:");
  struct tracked_processes tracked = guard_processes(ttyname(slave));
  pid_t writer = spawn_started_paced_writer(master, 'x', tail);
  if (kill(wrapper, signal_number) != 0) fail("wrapper-signal");

  wait_for_writer(writer);
  if (!echo_disabled(slave)) fail("wrapper-term-restored-before-writer-complete");
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "wrapper-term-exit");
  if (process_exit_status(&capture) != expected_status)
    fail("wrapper-term-status");
  wait_for_state(slave, initial);
  wait_for_processes_exit(&tracked);
  finish_child(child, master, &capture);
  if (contains(&capture, tail)) fail("wrapper-term-tail-captured");
}

static void run_wrapper_path_substitution(int master, int slave, pid_t child,
                                          const struct termios *initial) {
  struct capture capture = {0};
  char completion_dir[PATH_MAX];
  char moved_dir[PATH_MAX];

  read_until(master, &capture, "Console username: ", "path-substitution-prompt");
  if (!echo_disabled(slave)) fail("path-substitution-echo");
  pid_t wrapper = read_marked_pid(master, &capture, "__ORCHARD_WRAPPER_PID__:");
  read_marked_path(master, &capture, "__ORCHARD_CUSTODY_DIR__:", completion_dir,
                   sizeof(completion_dir));
  struct tracked_processes tracked = guard_processes(ttyname(slave));
  int length = snprintf(moved_dir, sizeof(moved_dir), "%s.moved", completion_dir);
  if (length < 0 || (size_t)length >= sizeof(moved_dir)) fail("moved-path-size");
  if (rename(completion_dir, moved_dir) != 0) fail("custody-dir-rename");
  if (mkdir(completion_dir, 0700) != 0) fail("custody-dir-replacement");

  write_all(master, "\n", 1U);
  wait_for_state_while_reading(master, slave, initial, &capture);
  wait_for_processes_exit(&tracked);
  pid_t cli = read_marked_pid(master, &capture, "__ORCHARD_CLI_PID__:");
  wait_for_process_absence_while_reading(
      master, &capture, cli, wrapper, "cli-survived-path-substitution");
  (void)read_status_record(master, &capture, "__ORCHARD_CLI_REAPED__:",
                           "path-substitution-cli-reaped");
  if (!process_running(wrapper)) fail("wrapper-released-on-path-substitution");

  if (rmdir(completion_dir) != 0) fail("custody-replacement-remove");
  if (rename(moved_dir, completion_dir) != 0) fail("custody-dir-restore");
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "path-substitution-exit");
  if (process_exit_status(&capture) != 1)
    fail("path-substitution-status");
  wait_for_process_exit(wrapper, "wrapper-survived-path-substitution");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
}

static void run_guard_pre_ready_death(int master, int slave, pid_t child,
                                      const struct termios *initial) {
  struct capture capture = {0};
  char completion_dir[PATH_MAX];
  char moved_dir[PATH_MAX];

  read_until(master, &capture, "__ORCHARD_GUARD_PID__:",
             "guard-pid-marker");
  pid_t wrapper = read_marked_pid(master, &capture, "__ORCHARD_WRAPPER_PID__:");
  pid_t guard = read_marked_pid(master, &capture, "__ORCHARD_GUARD_PID__:");
  read_marked_path(master, &capture, "__ORCHARD_CUSTODY_DIR__:", completion_dir,
                   sizeof(completion_dir));
  /* PID publication can precede the guard opening its custody directory. */
  if (read_marked_pid(master, &capture, "__ORCHARD_GUARD_PRE_READY__:") != guard)
    fail("guard-pre-ready-pid");
  int length = snprintf(moved_dir, sizeof(moved_dir), "%s.moved", completion_dir);
  if (length < 0 || (size_t)length >= sizeof(moved_dir)) fail("moved-path-size");
  if (rename(completion_dir, moved_dir) != 0) fail("guard-custody-dir-rename");
  if (mkdir(completion_dir, 0700) != 0) fail("guard-custody-dir-replacement");
  if (kill(guard, SIGKILL) != 0) fail("guard-kill");

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "guard-death-exit");
  if (process_exit_status(&capture) == 0) fail("guard-death-succeeded");
  if (contains(&capture, "__ORCHARD_CLI_PID__:")) fail("guard-death-started-cli");
  wait_for_process_exit(wrapper, "wrapper-survived-guard-death");
  wait_for_state(slave, initial);
  if (access(completion_dir, F_OK) != 0) fail("guard-death-touched-replacement");
  if (rmdir(completion_dir) != 0) fail("guard-replacement-remove");
  if (rename(moved_dir, completion_dir) != 0) fail("guard-custody-dir-restore");
  if (rmdir(completion_dir) != 0) fail("guard-original-dir-remove");
  finish_child(child, master, &capture);
}

static void run_wrapper_wait_reap(int master, int slave, pid_t child,
                                  const struct termios *initial) {
  struct capture capture = {0};

  read_until(master, &capture, "__ORCHARD_FIXTURE_PID__:", "fixture-pid-marker");
  pid_t wrapper = read_marked_pid(master, &capture, "__ORCHARD_WRAPPER_PID__:");
  pid_t cli = read_marked_pid(master, &capture, "__ORCHARD_CLI_PID__:");
  pid_t fixture = read_marked_pid(master, &capture, "__ORCHARD_FIXTURE_PID__:");
  if (cli != fixture) fail("fixture-cli-pid-mismatch");
  if (kill(wrapper, SIGTERM) != 0) fail("wrapper-term");

  read_until(master, &capture, "__ORCHARD_FIXTURE_TERM__", "fixture-term");
  if (!process_running(cli)) fail("fixture-exited-without-delay");
  if (!process_running(wrapper)) fail("wrapper-exited-before-cli");
  if (complete_record(&capture, "__ORCHARD_PROCESS_EXIT__:"))
    fail("process-exit-before-cli");

  read_until_while_process_running(master, &capture,
                                   "__ORCHARD_FIXTURE_EXIT_BARRIER__",
                                   "fixture-exit-barrier", wrapper);
  if (!process_running(cli)) fail("fixture-exited-before-exit-barrier");
  wait_for_process_absence_while_reading(master, &capture, cli, wrapper,
                                         "cli-survived-wrapper");
  if (read_status_record(master, &capture, "__ORCHARD_CLI_REAPED__:",
                         "cli-reaped-marker") != 143)
    fail("cli-reaped-status");
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "wrapper-term-exit");
  if (process_exit_status(&capture) != 143) fail("wrapper-term-status");
  wait_for_process_exit(wrapper, "wrapper-survived-cli-reap");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
}

static void run_wrapper_pre_ready_death(int master, int slave, pid_t child,
                                        const struct termios *initial,
                                        int signal_number) {
  struct capture capture = {0};
  char completion_dir[PATH_MAX];

  read_until(master, &capture, "__ORCHARD_GUARD_PID__:",
             "wrapper-death-guard-marker");
  pid_t wrapper = read_marked_pid(master, &capture, "__ORCHARD_WRAPPER_PID__:");
  pid_t guard = read_marked_pid(master, &capture, "__ORCHARD_GUARD_PID__:");
  read_marked_path(master, &capture, "__ORCHARD_CUSTODY_DIR__:", completion_dir,
                   sizeof(completion_dir));
  if (kill(wrapper, signal_number) != 0) fail("wrapper-kill");

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:",
             "wrapper-death-exit");
  if (process_exit_status(&capture) == 0)
    fail("wrapper-death-succeeded");
  if (signal_number == SIGTERM) {
    int status = process_exit_status(&capture);
    if (status != 143) {
      fprintf(stderr, "wrapper TERM status: %d\n", status);
      fail("wrapper-term-status");
    }
  }
  if (contains(&capture, "__ORCHARD_CLI_PID__:"))
    fail("wrapper-death-started-cli");
  wait_for_process_absence(wrapper, "wrapper-survived-pre-ready-death");
  wait_for_process_absence(guard, "guard-survived-wrapper-death");
  wait_for_state(slave, initial);
  if (access(completion_dir, F_OK) == 0)
    fail("wrapper-death-directory-survived");
  finish_child(child, master, &capture);
}

static void run_wrapper_pre_launch_signal(int master, int slave, pid_t child,
                                          const struct termios *initial,
                                          int signal_number,
                                          int expected_status) {
  struct capture capture = {0};
  char completion_dir[PATH_MAX];

  read_until(master, &capture, "__ORCHARD_PRE_LAUNCH__", "pre-launch-marker");
  pid_t wrapper = read_marked_pid(master, &capture, "__ORCHARD_WRAPPER_PID__:");
  pid_t guard = read_marked_pid(master, &capture, "__ORCHARD_GUARD_PID__:");
  read_marked_path(master, &capture, "__ORCHARD_CUSTODY_DIR__:", completion_dir,
                   sizeof(completion_dir));
  if (signal_number == SIGINT) {
    write_all(master, &initial->c_cc[VINTR], 1U);
  } else if (signal_number == SIGQUIT) {
    write_all(master, &initial->c_cc[VQUIT], 1U);
  } else if (kill(wrapper, signal_number) != 0) {
    fail("pre-launch-wrapper-signal");
  }

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "pre-launch-exit");
  if (process_exit_status(&capture) != expected_status) fail("pre-launch-status");
  if (contains(&capture, "__ORCHARD_CLI_PID__:")) fail("pre-launch-started-cli");
  wait_for_process_absence(wrapper, "pre-launch-wrapper-survived");
  wait_for_process_absence(guard, "pre-launch-guard-survived");
  wait_for_state(slave, initial);
  if (access(completion_dir, F_OK) == 0) fail("pre-launch-directory-survived");
  finish_child(child, master, &capture);
}

static void run_wrapper_launch_path_substitution(
    int master, int slave, pid_t child, const struct termios *initial) {
  struct capture capture = {0};
  char completion_dir[PATH_MAX];
  char moved_dir[PATH_MAX];
  char launch_marker[PATH_MAX];

  read_until(master, &capture, "__ORCHARD_PRE_LAUNCH__",
             "launch-substitution-barrier");
  read_until(master, &capture, "__ORCHARD_LAUNCH_WINDOW__",
             "launch-substitution-window");
  pid_t wrapper = read_marked_pid(master, &capture, "__ORCHARD_WRAPPER_PID__:");
  pid_t guard = read_marked_pid(master, &capture, "__ORCHARD_GUARD_PID__:");
  pid_t launcher =
      read_marked_pid(master, &capture, "__ORCHARD_LAUNCHER_PID__:");
  read_marked_path(master, &capture, "__ORCHARD_CUSTODY_DIR__:", completion_dir,
                   sizeof(completion_dir));
  int length = snprintf(moved_dir, sizeof(moved_dir), "%s.moved", completion_dir);
  if (length < 0 || (size_t)length >= sizeof(moved_dir)) fail("moved-path-size");
  length = snprintf(launch_marker, sizeof(launch_marker), "%s/launch-cli",
                    completion_dir);
  if (length < 0 || (size_t)length >= sizeof(launch_marker))
    fail("launch-marker-size");

  if (rename(completion_dir, moved_dir) != 0) fail("launch-custody-rename");
  if (mkdir(completion_dir, 0700) != 0) fail("launch-custody-replacement");
  if (kill(wrapper, SIGKILL) != 0) fail("launch-wrapper-kill");
  wait_for_process_absence(wrapper, "launch-wrapper-survived");
  int marker = open(launch_marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
  if (marker < 0) fail("substitute-launch-marker");
  close(marker);

  wait_for_process_absence(launcher, "launcher-trusted-substituted-path");

  if (unlink(launch_marker) != 0) fail("substitute-launch-marker-remove");
  if (rmdir(completion_dir) != 0) fail("launch-replacement-remove");
  if (rename(moved_dir, completion_dir) != 0) fail("launch-custody-restore");
  wait_for_process_absence(guard, "launch-guard-survived");
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:",
             "launch-substitution-exit");
  if (contains(&capture, "__ORCHARD_FIXTURE_PID__:"))
    fail("substituted-path-launched-cli");
  if (process_exit_status(&capture) == 0) fail("launch-substitution-succeeded");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
}

static void run_wrapper_setup_failure(int master, int slave, pid_t child,
                                      const struct termios *initial) {
  struct capture capture = {0};
  char completion_dir[PATH_MAX];

  read_until(master, &capture, "__ORCHARD_CUSTODY_DIR__:",
             "setup-failure-custody-marker");
  pid_t wrapper = read_marked_pid(master, &capture, "__ORCHARD_WRAPPER_PID__:");
  read_marked_path(master, &capture, "__ORCHARD_CUSTODY_DIR__:", completion_dir,
                   sizeof(completion_dir));

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:",
             "wrapper-setup-failure-exit");
  if (process_exit_status(&capture) == 0)
    fail("wrapper-setup-failure-succeeded");
  if (contains(&capture, "__ORCHARD_GUARD_PID__:"))
    fail("wrapper-setup-failure-started-guard");
  if (contains(&capture, "__ORCHARD_CLI_PID__:"))
    fail("wrapper-setup-failure-started-cli");
  wait_for_process_absence(wrapper, "wrapper-survived-setup-failure");
  wait_for_state(slave, initial);
  if (access(completion_dir, F_OK) == 0)
    fail("wrapper-setup-failure-directory-survived");
  finish_child(child, master, &capture);
}

static void run_terminal_close(int master, int slave, pid_t child) {
  struct capture capture = {0};
  char completion_dir[PATH_MAX];

  read_until(master, &capture, "Console username: ", "terminal-close-prompt");
  pid_t wrapper = read_marked_pid(master, &capture, "__ORCHARD_WRAPPER_PID__:");
  read_marked_path(master, &capture, "__ORCHARD_CUSTODY_DIR__:", completion_dir,
                   sizeof(completion_dir));
  struct tracked_processes tracked = guard_processes(ttyname(slave));

  close(slave);
  close(master);
  wait_for_processes_exit(&tracked);
  wait_for_process_exit(wrapper, "wrapper-survived-terminal-close");
  int status = wait_for_child_exit(child);
  if (WIFEXITED(status) && WEXITSTATUS(status) == 0) fail("terminal-close-succeeded");

  char active_marker[PATH_MAX];
  int length = snprintf(active_marker, sizeof(active_marker), "%s/active", completion_dir);
  if (length < 0 || (size_t)length >= sizeof(active_marker)) fail("active-marker-size");
  if (access(active_marker, F_OK) == 0) fail("terminal-close-custody-survived");
  if (rmdir(completion_dir) != 0 && errno != ENOENT)
    fail("terminal-close-directory-not-empty");
}

static void run_interruption(int master, int slave, pid_t child,
                             const struct termios *initial) {
  struct capture capture = {0};
  read_until(master, &capture, "Console username: ", "interrupt-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-interruption");

  write_all(master, &initial->c_cc[VINTR], 1U);
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "interrupt-exit");
  if (process_exit_status(&capture) == 0) fail("interrupt-succeeded");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
}

static void run_quit(int master, int slave, pid_t child,
                     const struct termios *initial) {
  struct capture capture = {0};
  read_until(master, &capture, "Console username: ", "quit-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-quit");

  write_all(master, &initial->c_cc[VQUIT], 1U);
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "quit-exit");
  if (process_exit_status(&capture) == 0) fail("quit-succeeded");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
}

static void wait_for_stop(pid_t child) {
  long long deadline = now_ms() + TIMEOUT_MS;
  while (now_ms() < deadline) {
    int status;
    pid_t waited = waitpid(child, &status, WNOHANG | WUNTRACED);
    if (waited == child && WIFSTOPPED(status)) return;
    if (waited < 0 && errno != EINTR) fail("stop-wait");
    usleep(10000);
  }
  fail("foreground-group-not-stopped");
}

static void run_stop(int master, int slave, pid_t child,
                     const struct termios *initial) {
  struct capture capture = {0};
  read_until(master, &capture, "Console username: ", "stop-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-stop");

  write_all(master, &initial->c_cc[VSUSP], 1U);
  wait_for_state(slave, initial);
  wait_for_stop(child);
  if (kill(-child, SIGCONT) != 0) fail("continue-signal");

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "stop-exit");
  if (process_exit_status(&capture) == 0) fail("stop-succeeded");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
}

static void run_stop_backpressure(int master, int slave, pid_t child,
                                  const struct termios *initial) {
  struct capture capture = {0};
  char secret[48];
  generated_value(secret, sizeof(secret), "credential");

  read_until(master, &capture, "Console username: ", "stop-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-stop");
  pid_t writer = spawn_backpressure_writer(master, initial->c_cc[VSUSP], secret);

  wait_for_state(slave, initial);
  wait_for_stop(child);
  wait_for_writer(writer);
  if (kill(-child, SIGCONT) != 0) fail("continue-signal");

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "stop-exit");
  if (process_exit_status(&capture) == 0) fail("stop-succeeded");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
  if (contains(&capture, secret)) fail("secret-captured");
}

static void run_stop_paced(int master, int slave, pid_t child,
                           const struct termios *initial) {
  struct capture capture = {0};
  char secret[48];
  generated_value(secret, sizeof(secret), "credential");

  read_until(master, &capture, "Console username: ", "stop-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-stop");
  pid_t writer = spawn_paced_writer(master, initial->c_cc[VSUSP], secret);

  wait_for_writer(writer);
  wait_for_state(slave, initial);
  wait_for_stop(child);
  if (kill(-child, SIGCONT) != 0) fail("continue-signal");
  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "stop-exit");
  if (process_exit_status(&capture) == 0) fail("stop-succeeded");
  wait_for_state(slave, initial);
  finish_child(child, master, &capture);
  if (contains(&capture, secret)) fail("secret-captured");
}

static void configure_initial_state(int slave, struct termios *initial, int echo_on) {
  if (tcgetattr(slave, initial) != 0) fail("get-initial-state");
  initial->c_lflag |= ICANON | ISIG;
  if (echo_on) {
    initial->c_lflag |= ECHO;
  } else {
    initial->c_lflag &= (tcflag_t)~ECHO;
  }
  initial->c_lflag &= (tcflag_t)~ECHONL;
  if (tcsetattr(slave, TCSANOW, initial) != 0) fail("set-initial-state");
  if (tcgetattr(slave, initial) != 0) fail("confirm-initial-state");
}

static void run_fragmented_record_case(int expected_setup_error) {
  int descriptors[2];
  int release[2];
  if (pipe(descriptors) != 0) fail("record-self-test-pipe");
  if (pipe(release) != 0) fail("record-self-test-release-pipe");

  pid_t writer = fork();
  if (writer < 0) fail("record-self-test-fork");
  if (writer == 0) {
    close(descriptors[0]);
    close(release[1]);
    const char *prefix = expected_setup_error
                             ? "could not disable terminal echo\n"
                               "__ORCHARD_PROCESS_EXIT__:"
                             : "__ORCHARD_PROCESS_EXIT__:";
    write_all(descriptors[1], prefix, strlen(prefix));
    char released;
    ssize_t count;
    do {
      count = read(release[0], &released, 1U);
    } while (count < 0 && errno == EINTR);
    if (count != 1) _exit(1);
    close(release[0]);
    write_all(descriptors[1], "0\n", 2U);
    close(descriptors[1]);
    _exit(0);
  }

  close(descriptors[1]);
  close(release[0]);
  if (fragmented_record_release_fd >= 0) fail("record-self-test-release-state");
  fragmented_record_release_fd = release[1];
  struct capture capture = {0};
  if (expected_setup_error) {
    read_until_expected_setup_exit(descriptors[0], &capture);
  } else {
    read_until(descriptors[0], &capture, "__ORCHARD_PROCESS_EXIT__:",
               "record-self-test-exit");
  }
  if (fragmented_record_release_fd >= 0) fail("record-self-test-not-released");
  if (process_exit_status(&capture) != 0)
    fail("fragmented-zero-status-misclassified");
  close(descriptors[0]);
  int status = wait_for_child_exit(writer);
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) fail("record-self-test-writer");
}

static void run_fragmented_path_case(void) {
  int descriptors[2];
  int release[2];
  if (pipe(descriptors) != 0) fail("path-self-test-pipe");
  if (pipe(release) != 0) fail("path-self-test-release-pipe");

  pid_t writer = fork();
  if (writer < 0) fail("path-self-test-fork");
  if (writer == 0) {
    close(descriptors[0]);
    close(release[1]);
    const char *prefix = "__ORCHARD_CUSTODY_DIR__:/private/tmp/orchard";
    write_all(descriptors[1], prefix, strlen(prefix));
    char released;
    ssize_t count;
    do {
      count = read(release[0], &released, 1U);
    } while (count < 0 && errno == EINTR);
    if (count != 1) _exit(1);
    close(release[0]);
    write_all(descriptors[1], ".complete\n", 10U);
    close(descriptors[1]);
    _exit(0);
  }

  close(descriptors[1]);
  close(release[0]);
  if (fragmented_record_release_fd >= 0) fail("path-self-test-release-state");
  fragmented_record_release_fd = release[1];
  struct capture capture = {0};
  char path[PATH_MAX];
  read_marked_path(descriptors[0], &capture, "__ORCHARD_CUSTODY_DIR__:", path,
                   sizeof(path));
  if (fragmented_record_release_fd >= 0) fail("path-self-test-not-released");
  if (strcmp(path, "/private/tmp/orchard.complete") != 0)
    fail("fragmented-path-misclassified");
  close(descriptors[0]);
  int status = wait_for_child_exit(writer);
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) fail("path-self-test-writer");
}

static void run_fragmented_record_self_test(void) {
  run_fragmented_record_case(0);
  run_fragmented_record_case(1);
  run_fragmented_path_case();
}

int main(int argc, char **argv) {
  if (argc < 4 || strcmp(argv[2], "--") != 0) {
    fprintf(stderr, "usage: console_pty_harness SCENARIO -- COMMAND [ARGS...]\n");
    return 64;
  }

  scenario_name = argv[1];
  if (strcmp(scenario_name, "fragmented-record-self-test") == 0) {
    run_fragmented_record_self_test();
    printf("console PTY ok: %s\n", scenario_name);
    return 0;
  }

  int probe_master = -1;
  int probe_slave = -1;
  if (openpty(&probe_master, &probe_slave, NULL, NULL, NULL) != 0) fail("openpty");

  struct termios initial;
  int echo_on = strcmp(scenario_name, "eof") != 0 &&
                strcmp(scenario_name, "exception") != 0;
  configure_initial_state(probe_slave, &initial, echo_on);
  close(probe_master);
  close(probe_slave);

  int master = -1;
  char slave_name[128];
  pid_t child = spawn_child(&master, slave_name, &initial, &argv[3]);

  int slave = open(slave_name, O_RDWR | O_NOCTTY);
  if (slave < 0) fail("open-slave");

  if (strcmp(scenario_name, "pasted-success") == 0) {
    run_pasted(master, slave, child, &initial, 1, 0, NULL);
  } else if (strcmp(scenario_name, "pasted-mismatch") == 0) {
    run_pasted(master, slave, child, &initial, 0, 0, NULL);
  } else if (strcmp(scenario_name, "wrapper-success-not-loaded") == 0) {
    run_pasted(master, slave, child, &initial, 1, 0,
               "Controller is not loaded.");
  } else if (strcmp(scenario_name, "wrapper-success-loaded") == 0) {
    run_pasted(master, slave, child, &initial, 1, 0,
               "Controller restarted.");
  } else if (strcmp(scenario_name, "wrapper-success-rotate") == 0) {
    run_pasted(master, slave, child, &initial, 1, 0,
               "Console credentials rotated.");
  } else if (strcmp(scenario_name, "unwrapped") == 0) {
    run_setup_failure(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "delayed-success") == 0) {
    run_pasted(master, slave, child, &initial, 1, 6000, NULL);
  } else if (strcmp(scenario_name, "utf8-erase") == 0) {
    run_utf8_erase(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "owner-exit") == 0) {
    run_owner_exit(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "owner-exit-paced") == 0) {
    run_owner_exit_paced(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "wrapper-term-paced") == 0) {
    run_wrapper_signal_paced(master, slave, child, &initial, SIGTERM, 143);
  } else if (strcmp(scenario_name, "wrapper-int-paced") == 0) {
    run_wrapper_signal_paced(master, slave, child, &initial, SIGINT, 130);
  } else if (strcmp(scenario_name, "wrapper-quit-paced") == 0) {
    run_wrapper_signal_paced(master, slave, child, &initial, SIGQUIT, 131);
  } else if (strcmp(scenario_name, "wrapper-path-substitution") == 0) {
    run_wrapper_path_substitution(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "guard-pre-ready-death") == 0) {
    run_guard_pre_ready_death(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "wrapper-pre-ready-death") == 0) {
    run_wrapper_pre_ready_death(master, slave, child, &initial, SIGKILL);
  } else if (strcmp(scenario_name, "wrapper-pre-ready-term") == 0) {
    run_wrapper_pre_ready_death(master, slave, child, &initial, SIGTERM);
  } else if (strcmp(scenario_name, "wrapper-pre-launch-term") == 0) {
    run_wrapper_pre_launch_signal(master, slave, child, &initial, SIGTERM, 143);
  } else if (strcmp(scenario_name, "wrapper-pre-launch-int") == 0) {
    run_wrapper_pre_launch_signal(master, slave, child, &initial, SIGINT, 130);
  } else if (strcmp(scenario_name, "wrapper-pre-launch-quit") == 0) {
    run_wrapper_pre_launch_signal(master, slave, child, &initial, SIGQUIT, 131);
  } else if (strcmp(scenario_name, "wrapper-launch-path-substitution") == 0) {
    run_wrapper_launch_path_substitution(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "wrapper-late-int") == 0) {
    run_wrapper_late_int(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "wrapper-cli-post-wait-int") == 0) {
    run_wrapper_post_wait_int(master, slave, child, &initial,
                              "__ORCHARD_CLI_POST_WAIT__", 1);
  } else if (strcmp(scenario_name, "wrapper-guard-post-wait-int") == 0) {
    run_wrapper_post_wait_int(master, slave, child, &initial,
                              "__ORCHARD_GUARD_POST_WAIT__", 0);
  } else if (strcmp(scenario_name, "wrapper-setup-failure") == 0) {
    run_wrapper_setup_failure(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "wrapper-wait-reap") == 0) {
    run_wrapper_wait_reap(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "terminal-close") == 0) {
    run_terminal_close(master, slave, child);
  } else if (strcmp(scenario_name, "eof") == 0) {
    run_eof(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "exception") == 0) {
    run_exception(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "setup-failure") == 0) {
    run_setup_failure(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "watchdog-handshake") == 0) {
    run_setup_failure(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "watchdog-protected-handshake") == 0) {
    run_protected_setup_paced(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "restorer-parent-kill") == 0) {
    run_restorer_parent_kill(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "restorer-pre-teardown-kill") == 0) {
    run_restorer_pre_teardown_kill(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "restorer-identity-retry") == 0) {
    run_restorer_identity_retry(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "watchdog-custody-handshake") == 0) {
    run_watchdog_custody_handshake(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "restorer-signal-setup") == 0) {
    run_restorer_signal_setup(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "post-protect") == 0) {
    run_setup_failure(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "signal-int") == 0 ||
             strcmp(scenario_name, "signal-hup") == 0 ||
             strcmp(scenario_name, "signal-term") == 0 ||
             strcmp(scenario_name, "signal-kill") == 0 ||
             strcmp(scenario_name, "marker-pre-ready-kill") == 0 ||
             strcmp(scenario_name, "watchdog-idle") == 0 ||
             strcmp(scenario_name, "watchdog-read") == 0) {
    run_helper_signal(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "port-owner-exit") == 0) {
    run_port_owner_exit(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "interruption") == 0) {
    run_interruption(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "quit") == 0) {
    run_quit(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "stop") == 0) {
    run_stop(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "stop-backpressure") == 0) {
    run_stop_backpressure(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "stop-paced") == 0) {
    run_stop_paced(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "invalid-username-paste") == 0) {
    run_invalid_username_paste(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "invalid-username-backpressure") == 0) {
    run_invalid_username_backpressure(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "invalid-username-paced") == 0) {
    run_invalid_username_paced(master, slave, child, &initial);
  } else {
    kill(child, SIGKILL);
    waitpid(child, NULL, 0);
    fail("unknown-scenario");
  }

  close(master);
  close(slave);
  printf("console PTY ok: %s\n", scenario_name);
  return 0;
}
