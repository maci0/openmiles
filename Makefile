.PHONY: all build test clean lint format check-header parity help

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

# Per-version export-parity sweep; needs the reference DLLs under references/.
parity:
	./scripts/check_all_versions.sh

help:
	@echo "Targets:"
	@echo "  build    build the library and the test binaries (zig build)"
	@echo "  test     run the test suite (zig build test)"
	@echo "  lint     check formatting and shellcheck the scripts"
	@echo "  format   apply zig fmt"
	@echo "  parity   diff every -Dmss-version export table against its reference DLL"
	@echo "  clean    remove zig-out and .zig-cache"
	@echo "  help     show this message"
