#define _DARWIN_C_SOURCE

#include <errno.h>
#include <libproc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>

enum snapshot_scenario {
  SCENARIO_FALLBACK_NONBEAM,
  SCENARIO_FALLBACK_PERMISSION_NONBEAM,
  SCENARIO_FALLBACK_BEAM,
  SCENARIO_FALLBACK_EMPTY_NAME,
  SCENARIO_FALLBACK_UNTERMINATED_NAME,
  SCENARIO_FALLBACK_DENIED,
  SCENARIO_FALLBACK_GONE,
  SCENARIO_FALLBACK_ZERO_SIZE,
  SCENARIO_FALLBACK_TRUNCATED,
  SCENARIO_FALLBACK_PID_MISMATCH,
  SCENARIO_EXPECTED_FALLBACK_DENIED,
  SCENARIO_EXPECTED_FALLBACK_NONBEAM,
  SCENARIO_POSITIVE_EXPECTED_BEAM,
  SCENARIO_INACCESSIBLE_THEN_EXPECTED_BEAM
};

static const pid_t fixture_pid = 4242;
static const pid_t second_fixture_pid = 4343;
static enum snapshot_scenario active_scenario;
static const char *fixture_executable;

static int mock_proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer,
                              int buffersize);
static int mock_proc_pidpath(int pid, void *buffer, uint32_t buffersize);
int mock_proc_name(int pid, void *buffer, uint32_t buffersize);
static int mock_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                       void *newp, size_t newlen);

#define main orchard_lifecycle_helper_main
#define proc_listpids mock_proc_listpids
#define proc_name mock_proc_name
#define proc_pidpath mock_proc_pidpath
#define sysctl mock_sysctl
#ifndef ORCHARD_LIFECYCLE_HELPER_SOURCE
#define ORCHARD_LIFECYCLE_HELPER_SOURCE                                        \
  "../../../../packaging/macos/native_helpers/orchard_lifecycle_helper.c"
#endif
#include ORCHARD_LIFECYCLE_HELPER_SOURCE
#undef sysctl
#undef proc_pidpath
#undef proc_name
#undef proc_listpids
#undef main

static int parse_scenario(const char *name, enum snapshot_scenario *scenario) {
  struct scenario_name {
    const char *name;
    enum snapshot_scenario scenario;
  };
  static const struct scenario_name scenarios[] = {
      {"fallback-nonbeam", SCENARIO_FALLBACK_NONBEAM},
      {"fallback-permission-nonbeam", SCENARIO_FALLBACK_PERMISSION_NONBEAM},
      {"fallback-beam", SCENARIO_FALLBACK_BEAM},
      {"fallback-empty-name", SCENARIO_FALLBACK_EMPTY_NAME},
      {"fallback-unterminated-name", SCENARIO_FALLBACK_UNTERMINATED_NAME},
      {"fallback-denied", SCENARIO_FALLBACK_DENIED},
      {"fallback-gone", SCENARIO_FALLBACK_GONE},
      {"fallback-zero-size", SCENARIO_FALLBACK_ZERO_SIZE},
      {"fallback-truncated", SCENARIO_FALLBACK_TRUNCATED},
      {"fallback-pid-mismatch", SCENARIO_FALLBACK_PID_MISMATCH},
      {"expected-fallback-denied", SCENARIO_EXPECTED_FALLBACK_DENIED},
      {"expected-fallback-nonbeam", SCENARIO_EXPECTED_FALLBACK_NONBEAM},
      {"positive-expected-beam", SCENARIO_POSITIVE_EXPECTED_BEAM},
      {"inaccessible-then-expected-beam",
       SCENARIO_INACCESSIBLE_THEN_EXPECTED_BEAM},
  };

  for (size_t index = 0; index < sizeof(scenarios) / sizeof(scenarios[0]);
       index++) {
    if (strcmp(name, scenarios[index].name) == 0) {
      *scenario = scenarios[index].scenario;
      return 0;
    }
  }
  return -1;
}

static int mock_proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer,
                              int buffersize) {
  pid_t pids[2] = {fixture_pid, second_fixture_pid};
  size_t count =
      active_scenario == SCENARIO_INACCESSIBLE_THEN_EXPECTED_BEAM ? 2 : 1;
  size_t byte_count = count * sizeof(pids[0]);

  if (type != PROC_ALL_PIDS || typeinfo != 0) {
    errno = EINVAL;
    return -1;
  }
  if (buffer == NULL) {
    return (int)byte_count;
  }
  if (buffersize < (int)byte_count) {
    errno = ENOMEM;
    return -1;
  }
  memcpy(buffer, pids, byte_count);
  return (int)byte_count;
}

static int mock_proc_pidpath(int pid, void *buffer, uint32_t buffersize) {
  size_t executable_size;
  int path_accessible =
      (active_scenario == SCENARIO_POSITIVE_EXPECTED_BEAM &&
       pid == fixture_pid) ||
      (active_scenario == SCENARIO_INACCESSIBLE_THEN_EXPECTED_BEAM &&
       pid == second_fixture_pid);

  if (pid != fixture_pid && pid != second_fixture_pid) {
    errno = ESRCH;
    return 0;
  }
  if (!path_accessible) {
    errno = active_scenario == SCENARIO_FALLBACK_PERMISSION_NONBEAM ? EACCES
                                                                    : ENOENT;
    return 0;
  }

  executable_size = strlen(fixture_executable) + 1;
  if (executable_size > buffersize) {
    errno = ENOSPC;
    return 0;
  }
  memcpy(buffer, fixture_executable, executable_size);
  return (int)executable_size;
}

int mock_proc_name(int pid, void *buffer, uint32_t buffersize) {
  (void)buffer;
  (void)buffersize;

  if (pid != fixture_pid) {
    errno = ESRCH;
    return 0;
  }
  errno =
      active_scenario == SCENARIO_FALLBACK_PERMISSION_NONBEAM ? EACCES : EPERM;
  return 0;
}

static void fill_process(struct kinfo_proc *process) {
  memset(process, 0, sizeof(*process));
  process->kp_proc.p_pid = fixture_pid;
  process->kp_proc.p_starttime.tv_sec = 1700000000;
  process->kp_proc.p_starttime.tv_usec = 123456;

  switch (active_scenario) {
  case SCENARIO_FALLBACK_NONBEAM:
  case SCENARIO_FALLBACK_PERMISSION_NONBEAM:
  case SCENARIO_FALLBACK_TRUNCATED:
  case SCENARIO_FALLBACK_PID_MISMATCH:
  case SCENARIO_EXPECTED_FALLBACK_NONBEAM:
    strcpy(process->kp_proc.p_comm, "python3");
    break;
  case SCENARIO_FALLBACK_BEAM:
  case SCENARIO_POSITIVE_EXPECTED_BEAM:
    strcpy(process->kp_proc.p_comm, "beam.smp");
    break;
  case SCENARIO_FALLBACK_UNTERMINATED_NAME:
    memset(process->kp_proc.p_comm, 'x', sizeof(process->kp_proc.p_comm));
    break;
  case SCENARIO_FALLBACK_EMPTY_NAME:
  case SCENARIO_FALLBACK_DENIED:
  case SCENARIO_FALLBACK_GONE:
  case SCENARIO_FALLBACK_ZERO_SIZE:
  case SCENARIO_EXPECTED_FALLBACK_DENIED:
    break;
  case SCENARIO_INACCESSIBLE_THEN_EXPECTED_BEAM:
    if (process->kp_proc.p_pid == fixture_pid) {
      strcpy(process->kp_proc.p_comm, "python3");
    } else {
      strcpy(process->kp_proc.p_comm, "beam.smp");
    }
    break;
  }
}

static int mock_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                       void *newp, size_t newlen) {
  struct kinfo_proc process;
  pid_t requested_pid;
  size_t returned_size = sizeof(process);

  (void)newp;
  (void)newlen;

  if (namelen != 4 || name[0] != CTL_KERN || name[1] != KERN_PROC ||
      name[2] != KERN_PROC_PID || oldp == NULL || oldlenp == NULL) {
    errno = EINVAL;
    return -1;
  }
  requested_pid = (pid_t)name[3];
  if (requested_pid != fixture_pid &&
      !(active_scenario == SCENARIO_INACCESSIBLE_THEN_EXPECTED_BEAM &&
        requested_pid == second_fixture_pid)) {
    errno = ESRCH;
    return -1;
  }

  if (active_scenario == SCENARIO_FALLBACK_DENIED ||
      active_scenario == SCENARIO_EXPECTED_FALLBACK_DENIED) {
    errno = EACCES;
    return -1;
  }
  if (active_scenario == SCENARIO_FALLBACK_GONE) {
    errno = ESRCH;
    return -1;
  }

  fill_process(&process);
  process.kp_proc.p_pid = requested_pid;
  if (active_scenario == SCENARIO_INACCESSIBLE_THEN_EXPECTED_BEAM) {
    if (requested_pid == fixture_pid) {
      strcpy(process.kp_proc.p_comm, "python3");
    } else {
      strcpy(process.kp_proc.p_comm, "beam.smp");
    }
  }
  if (active_scenario == SCENARIO_FALLBACK_ZERO_SIZE) {
    returned_size = 0;
  }
  if (active_scenario == SCENARIO_FALLBACK_TRUNCATED) {
    returned_size--;
  } else if (active_scenario == SCENARIO_FALLBACK_PID_MISMATCH) {
    process.kp_proc.p_pid++;
  }
  if (*oldlenp < returned_size) {
    errno = ENOMEM;
    return -1;
  }
  memcpy(oldp, &process, returned_size);
  *oldlenp = returned_size;
  return 0;
}

int main(int argc, char **argv) {
  const char *expected_pid_text = NULL;
  int result;

  if (argc != 3 || parse_scenario(argv[1], &active_scenario) != 0) {
    fprintf(stderr, "usage: %s SCENARIO BEAM_EXECUTABLE\n", argv[0]);
    return 64;
  }
  fixture_executable = argv[2];
  if (active_scenario == SCENARIO_EXPECTED_FALLBACK_DENIED ||
      active_scenario == SCENARIO_EXPECTED_FALLBACK_NONBEAM ||
      active_scenario == SCENARIO_POSITIVE_EXPECTED_BEAM) {
    expected_pid_text = "4242";
  } else if (active_scenario == SCENARIO_INACCESSIBLE_THEN_EXPECTED_BEAM) {
    expected_pid_text = "4343";
  }

  result = command_snapshot(expected_pid_text);
  return result;
}
