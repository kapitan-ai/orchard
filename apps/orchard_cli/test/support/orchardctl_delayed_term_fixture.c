#include <signal.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t termination_requested;

static void request_termination(int signal_number) {
  (void)signal_number;
  termination_requested = 1;
}

int main(void) {
  struct sigaction action = {0};
  action.sa_handler = request_termination;
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGTERM, &action, NULL) != 0) return 126;

  printf("__ORCHARD_FIXTURE_PID__:%d\n", getpid());
  fflush(stdout);
  while (!termination_requested) pause();

  printf("__ORCHARD_FIXTURE_TERM__\n");
  fflush(stdout);
  struct timespec delay = {.tv_sec = 1, .tv_nsec = 0};
  while (nanosleep(&delay, &delay) != 0) {
  }
  printf("__ORCHARD_FIXTURE_EXIT_BARRIER__\n");
  fflush(stdout);
  struct timespec exit_barrier = {.tv_sec = 0, .tv_nsec = 200000000};
  while (nanosleep(&exit_barrier, &exit_barrier) != 0) {
  }
  return 143;
}
