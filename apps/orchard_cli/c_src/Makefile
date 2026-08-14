PRIV_DIR := $(MIX_APP_PATH)/priv
TTY_TARGET := $(PRIV_DIR)/orchard-secret-tty
TTY_TEST_TARGET := $(PRIV_DIR)/orchard-secret-tty-test
TTY_SOURCE := orchard_secret_tty.c
LIFECYCLE_TARGET := $(PRIV_DIR)/orchard-lifecycle-helper
LIFECYCLE_SOURCE := orchard_lifecycle_helper.c

.PHONY: all clean

TARGETS := $(TTY_TARGET) $(LIFECYCLE_TARGET)
ifeq ($(MIX_ENV),test)
TARGETS += $(TTY_TEST_TARGET)
endif

all: $(TARGETS)

$(TTY_TARGET): $(TTY_SOURCE)
	mkdir -p $(PRIV_DIR)
	xcrun clang -std=c11 -Wall -Wextra -Werror -pedantic -O2 $(TTY_SOURCE) -o $(TTY_TARGET)

$(TTY_TEST_TARGET): $(TTY_SOURCE)
	mkdir -p $(PRIV_DIR)
	xcrun clang -std=c11 -Wall -Wextra -Werror -pedantic -O2 \
		-DORCHARD_SECRET_TTY_TEST $(TTY_SOURCE) -o $(TTY_TEST_TARGET)

$(LIFECYCLE_TARGET): $(LIFECYCLE_SOURCE)
	mkdir -p $(PRIV_DIR)
	xcrun clang -std=c11 -Wall -Wextra -Werror -pedantic -O2 $(LIFECYCLE_SOURCE) -o $(LIFECYCLE_TARGET)

clean:
	rm -f $(TTY_TARGET) $(TTY_TEST_TARGET) $(LIFECYCLE_TARGET)
