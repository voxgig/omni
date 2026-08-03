CC ?= gcc
CFLAGS ?= -std=c99 -Wall -Wextra -Werror -O2
LDLIBS ?= -lm

SRC = src/json.c src/util.c src/runner.c
TESTSRC = test/fib.c test/run.c

.PHONY: build test clean inspect

build:
	mkdir -p build
	$(CC) $(CFLAGS) -c $(SRC) -o /dev/null 2>/dev/null || true
	$(CC) $(CFLAGS) -o build/omnitest $(SRC) $(TESTSRC) $(LDLIBS)

test: build
	./build/omnitest

clean:
	rm -rf build

inspect:
	@$(CC) --version | head -1
