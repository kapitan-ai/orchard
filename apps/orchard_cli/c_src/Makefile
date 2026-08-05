PRIV_DIR := $(MIX_APP_PATH)/priv
TARGET := $(PRIV_DIR)/orchard-secret-tty
TEST_TARGET := $(PRIV_DIR)/orchard-secret-tty-test
SOURCE := orchard_secret_tty.c

.PHONY: all clean

TARGETS := $(TARGET)
ifeq ($(MIX_ENV),test)
TARGETS += $(TEST_TARGET)
endif

all: $(TARGETS)

$(TARGET): $(SOURCE)
	mkdir -p $(PRIV_DIR)
	xcrun clang -std=c11 -Wall -Wextra -Werror -pedantic -O2 $(SOURCE) -o $(TARGET)

$(TEST_TARGET): $(SOURCE)
	mkdir -p $(PRIV_DIR)
	xcrun clang -std=c11 -Wall -Wextra -Werror -pedantic -O2 \
		-DORCHARD_SECRET_TTY_TEST $(SOURCE) -o $(TEST_TARGET)

clean:
	rm -f $(TARGET) $(TEST_TARGET)
