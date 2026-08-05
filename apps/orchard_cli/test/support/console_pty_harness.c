#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

#define CAPTURE_LIMIT 65536
#define PROCESS_LIMIT 2048
#define TRACKED_PROCESS_LIMIT 32
#define TIMEOUT_MS 15000

struct capture {
  char bytes[CAPTURE_LIMIT];
  size_t length;
};

struct process_entry {
  pid_t pid;
  pid_t ppid;
  char command[64];
};

struct tracked_processes {
  pid_t values[TRACKED_PROCESS_LIMIT];
  size_t length;
};

static const char *scenario_name;

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

static pid_t owner_pid(const struct capture *capture) {
  const char *marker = "__ORCHARD_OWNER_PID__:";
  const char *cursor = find_bytes(capture, marker);
  if (cursor == NULL) fail("owner-marker");
  cursor += strlen(marker);

  pid_t owner = 0;
  while (cursor < capture->bytes + capture->length && *cursor >= '0' && *cursor <= '9') {
    owner = owner * 10 + (*cursor - '0');
    cursor++;
  }
  if (owner <= 0) fail("owner-marker");
  return owner;
}

static pid_t process_parent(const struct process_entry *entries, size_t count,
                            pid_t pid) {
  for (size_t index = 0; index < count; index++) {
    if (entries[index].pid == pid) return entries[index].ppid;
  }
  return 0;
}

static int descendant_of(const struct process_entry *entries, size_t count,
                         pid_t pid, pid_t ancestor) {
  for (size_t depth = 0; depth < count; depth++) {
    pid = process_parent(entries, count, pid);
    if (pid == ancestor) return 1;
    if (pid <= 1) return 0;
  }
  return 0;
}

static int shell_command(const char *command) {
  size_t length = strlen(command);
  return strcmp(command, "sh") == 0 ||
         (length >= 3 && strcmp(command + length - 3, "/sh") == 0);
}

static struct tracked_processes guard_processes(pid_t owner) {
  struct process_entry entries[PROCESS_LIMIT];
  size_t count = 0;
  FILE *processes = popen("/bin/ps -axo pid=,ppid=,comm=", "r");
  if (processes == NULL) fail("process-scan");

  char line[256];
  while (count < PROCESS_LIMIT && fgets(line, sizeof(line), processes) != NULL) {
    int pid = 0;
    int ppid = 0;
    char command[64];
    if (sscanf(line, "%d %d %63s", &pid, &ppid, command) == 3) {
      entries[count].pid = (pid_t)pid;
      entries[count].ppid = (pid_t)ppid;
      memcpy(entries[count].command, command, strlen(command) + 1);
      count++;
    }
  }
  if (pclose(processes) != 0) fail("process-scan");

  struct tracked_processes tracked = {0};
  for (size_t index = 0; index < count; index++) {
    if (shell_command(entries[index].command) &&
        descendant_of(entries, count, entries[index].pid, owner)) {
      if (tracked.length == TRACKED_PROCESS_LIMIT) fail("tracked-process-limit");
      tracked.values[tracked.length++] = entries[index].pid;
    }
  }
  if (tracked.length < 2) fail("guard-processes-not-found");
  return tracked;
}

static void wait_for_processes_exit(const struct tracked_processes *tracked) {
  long long deadline = now_ms() + TIMEOUT_MS;

  while (now_ms() < deadline) {
    int alive = 0;
    for (size_t index = 0; index < tracked->length; index++) {
      if (kill(tracked->values[index], 0) == 0 || errno == EPERM) alive = 1;
    }
    if (!alive) return;
    usleep(10000);
  }
  fail("secret-tty-process-survived-owner-exit");
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

  while (!contains(capture, needle)) {
    int remaining = (int)(deadline - now_ms());
    if (remaining <= 0) fail(stage);

    struct pollfd descriptor = {.fd = master, .events = POLLIN | POLLHUP};
    int ready = poll(&descriptor, 1, remaining);
    if (ready < 0 && errno == EINTR) continue;
    if (ready < 0) fail("poll");
    if (ready == 0) fail(stage);
    if (!read_once(master, capture) && !contains(capture, needle)) fail(stage);
  }
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
  struct termios actual;

  while (now_ms() < deadline) {
    if (tcgetattr(slave, &actual) == 0 && termios_equal(&actual, expected)) return;
    usleep(10000);
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
  shell_args[2] =
      "\"$@\" & owner=$!; trap '' INT; "
      "printf '__ORCHARD_OWNER_PID__:%s\\n' \"$owner\"; "
      "wait \"$owner\"; status=$?; "
      "printf '__ORCHARD_PTY_RESULT__:%s\\n' \"$status\"; "
      "printf '__ORCHARD_PROCESS_EXIT__:%s\\n' \"$status\"; sleep 30";
  shell_args[3] = "orchard-pty-owner";
  for (size_t index = 0; index < command_count; index++) {
    shell_args[index + 4] = command[index];
  }

  execv("/bin/sh", shell_args);
  _exit(127);
}

static void finish_child(pid_t session, pid_t owner, int master,
                         struct capture *capture) {
  if (kill(owner, 0) == 0) kill(owner, SIGKILL);
  read_until(master, capture, "__ORCHARD_PROCESS_EXIT__:", "owner-exit");
  kill(session, SIGKILL);
  if (waitpid(session, NULL, 0) < 0) fail("waitpid");
}

static void assert_failed_result(const struct capture *capture) {
  if (contains(capture, "__ORCHARD_PTY_RESULT__:0")) fail("unexpected-success");
}

static void generated_value(char *output, size_t length, const char *prefix) {
  snprintf(output, length, "%s-%08x-%08x", prefix, arc4random(), arc4random());
}

static void run_pasted(int master, int slave, pid_t child,
                       const struct termios *initial, int expect_success,
                       int delay_ms) {
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

  read_until(master, &capture, "__ORCHARD_PTY_RESULT__:", "result-marker");
  int successful_result = contains(&capture, "__ORCHARD_PTY_RESULT__:0");
  wait_for_state(slave, initial);

  pid_t owner = owner_pid(&capture);
  finish_child(child, owner, master, &capture);

  if (!protected_before_username) fail("echo-enabled-before-username-prompt");
  if (!protected_at_password) fail("echo-enabled-at-password-prompt");
  if (!protected_at_confirmation) fail("echo-enabled-at-confirmation-prompt");
  if (contains(&capture, password) || contains(&capture, confirmation)) fail("secret-captured");
  if (expect_success && !successful_result) fail("unexpected-exit");
  if (!expect_success && successful_result) fail("unexpected-success");
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

  read_until(master, &capture, "__ORCHARD_PTY_RESULT__:", "result-marker");
  assert_failed_result(&capture);
  wait_for_state(slave, initial);
  finish_child(child, owner_pid(&capture), master, &capture);
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

  read_until(master, &capture, "__ORCHARD_PTY_RESULT__:70", "exception-result");
  wait_for_state(slave, initial);
  finish_child(child, owner_pid(&capture), master, &capture);
  if (contains(&capture, input)) fail("exception-input-captured");
}

static void run_setup_failure(int master, int slave, pid_t child,
                              const struct termios *initial) {
  struct capture capture = {0};
  read_until(master, &capture, "__ORCHARD_PTY_RESULT__:", "setup-result");
  assert_failed_result(&capture);
  if (contains(&capture, "Console username: ") ||
      contains(&capture, "Console password: ")) {
    fail("prompt-rendered-before-setup");
  }
  wait_for_state(slave, initial);
  finish_child(child, owner_pid(&capture), master, &capture);
}

static void run_owner_exit(int master, int slave, pid_t child,
                           const struct termios *initial) {
  struct capture capture = {0};
  read_until(master, &capture, "Console username: ", "owner-exit-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-owner-exit");

  pid_t owner = owner_pid(&capture);
  struct tracked_processes tracked = guard_processes(owner);
  if (kill(owner, SIGKILL) != 0) fail("owner-kill");

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "owner-exit");
  wait_for_state(slave, initial);
  wait_for_processes_exit(&tracked);
  kill(child, SIGKILL);
  if (waitpid(child, NULL, 0) < 0) fail("waitpid");
}

static void run_interruption(int master, int slave, pid_t child,
                             const struct termios *initial) {
  struct capture capture = {0};
  read_until(master, &capture, "Console username: ", "interrupt-prompt");
  if (!echo_disabled(slave)) fail("echo-enabled-before-interruption");

  pid_t owner = owner_pid(&capture);
  if (kill(-child, SIGINT) != 0) fail("interrupt-signal");
  usleep(250000);

  if (kill(owner, 0) == 0) {
    if (!echo_disabled(slave)) fail("premature-interrupt-restoration");
    kill(owner, SIGKILL);
  }

  read_until(master, &capture, "__ORCHARD_PROCESS_EXIT__:", "interrupt-exit");
  wait_for_state(slave, initial);
  kill(child, SIGKILL);
  if (waitpid(child, NULL, 0) < 0) fail("waitpid");
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

int main(int argc, char **argv) {
  if (argc < 4 || strcmp(argv[2], "--") != 0) {
    fprintf(stderr, "usage: console_pty_harness SCENARIO -- COMMAND [ARGS...]\n");
    return 64;
  }

  scenario_name = argv[1];
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
    run_pasted(master, slave, child, &initial, 1, 0);
  } else if (strcmp(scenario_name, "pasted-mismatch") == 0) {
    run_pasted(master, slave, child, &initial, 0, 0);
  } else if (strcmp(scenario_name, "delayed-success") == 0) {
    run_pasted(master, slave, child, &initial, 1, 6000);
  } else if (strcmp(scenario_name, "owner-exit") == 0) {
    run_owner_exit(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "eof") == 0) {
    run_eof(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "exception") == 0) {
    run_exception(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "setup-failure") == 0) {
    run_setup_failure(master, slave, child, &initial);
  } else if (strcmp(scenario_name, "interruption") == 0) {
    run_interruption(master, slave, child, &initial);
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
