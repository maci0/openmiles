.PHONY: all build test clean lint format check-header check-toolchain parity help

# The one toolchain this project builds with. build.zig.zon carries
# .minimum_zig_version, but that is a floor, not the version the output was
# verified against; a stray zig on PATH would silently build anyway. Keep the
# two in sync: this value is what CI installs.
ZIG_VERSION := 0.16.0

all: build

# Fail before any compile work, with a clear message, rather than letting an
# unpinned zig produce artifacts nobody compared against the references.
check-toolchain:
	@command -v zig >/dev/null 2>&1 || { echo "error: zig $(ZIG_VERSION) not found on PATH" >&2; exit 1; }
	@v=`zig version`; [ "$$v" = "$(ZIG_VERSION)" ] || { echo "error: zig $(ZIG_VERSION) required, found $$v" >&2; exit 1; }

build: check-toolchain
	zig build

test: check-toolchain
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
