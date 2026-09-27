.PHONY: all build test clean lint format check-header

all: build

build:
	zig build

test:
	zig build test

# src/mss.h declares the C surface; src/main.zig is the export table it must
# agree with, for every -Dmss-version. See scripts/check_header.py.
check-header:
	./scripts/check_header.py

lint:
	zig fmt --check .
	shellcheck scripts/*.sh
	./scripts/check_header.py

format:
	zig fmt .

clean:
	rm -rf zig-out .zig-cache
