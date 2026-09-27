.PHONY: all build test check clean lint format check-header check-versions check-pins check-python check-toolchain check-vendored cross parity help

# The one toolchain this project builds with. build.zig.zon carries
# .minimum_zig_version, but that is a floor, not the version the output was
# verified against; a stray zig on PATH would silently build anyway. Read the
# version from build.zig.zon so it is declared once: CI and the release
# workflow read the same field, and nothing has to be kept in sync by hand.
ZIG_VERSION := $(shell sed -n 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon)

all: build

# Fail before any compile work, with a clear message, rather than letting an
# unpinned zig produce artifacts nobody compared against the references.
check-toolchain:
	@[ -n "$(ZIG_VERSION)" ] || { echo "error: no .minimum_zig_version in build.zig.zon" >&2; exit 1; }
	@command -v zig >/dev/null 2>&1 || { echo "error: zig $(ZIG_VERSION) not found on PATH" >&2; exit 1; }
	@v=`zig version`; [ "$$v" = "$(ZIG_VERSION)" ] || { echo "error: zig $(ZIG_VERSION) required, found $$v" >&2; exit 1; }

build: check-toolchain
	zig build

# make test FILTER=<substring> runs only the tests whose name contains it;
# the full suite takes minutes, the filtered run seconds.
test: check-toolchain
	zig build test $(if $(FILTER),-Dtest-filter=$(FILTER))

# Everything .github/workflows/ci.yml runs, in the same order, so a failure
# here is the same failure CI would give.
check: lint build test cross

# The shipped artifact. A build that only passes natively can still fail to
# link as a 32-bit stdcall DLL, so check what ships.
cross:
	zig build -Dtarget=x86-windows -Doptimize=ReleaseFast

# src/mss.h declares the C surface; src/main.zig is the export table it must
# agree with, and src/root.zig the struct layouts, for every -Dmss-version.
# See scripts/check_header.py.
check-header:
	./scripts/check_header.py

# Every -Dmss-version value must be swept against a reference DLL or declared
# unswept with a reason, and the three places that list the values must agree.
# See scripts/check_versions.py.
check-versions:
	./scripts/check_versions.py

# deps/ holds vendored upstream headers, not package-manager downloads, so
# deps/SHA256SUMS is the only record of which bytes were reviewed.
check-vendored:
	./scripts/check_vendored.py

# The gate scripts are the linter, so ruff checks them too: ruff.toml pins the
# rule set, and a script that crashes or stops reporting fails the gate
# silently. Pinned for the same reason as the zig above, so a newer local ruff
# cannot turn the tree red against a green CI.
RUFF_VERSION := 0.16.4

# The Zig and ruff pins live in the Makefile, ci.yml, and build.zig.zon; a
# stale one in CI installs the old tool and the gate quietly stops matching.
check-pins:
	./scripts/check_toolchain_pins.py

check-python:
	@command -v ruff >/dev/null 2>&1 || { echo "error: ruff $(RUFF_VERSION) not found on PATH" >&2; exit 1; }
	@v=`ruff --version | cut -d' ' -f2`; [ "$$v" = "$(RUFF_VERSION)" ] || { echo "error: ruff $(RUFF_VERSION) required, found $$v" >&2; exit 1; }
	ruff check .
	ruff format --check .

lint:
	zig fmt --check .
	shellcheck scripts/*.sh
	./scripts/check_header.py
	./scripts/check_versions.py
	./scripts/check_vendored.py
	@$(MAKE) --no-print-directory check-python
	@$(MAKE) --no-print-directory check-pins

format:
	zig fmt .
	ruff format .

clean:
	rm -rf zig-out .zig-cache

# Per-version export-parity sweep; needs the reference DLLs under references/.
parity:
	./scripts/check_all_versions.sh

help:
	@echo "Targets:"
	@echo "  build      build the library and the test binaries (zig build)"
	@echo "  test       run the test suite (zig build test); FILTER=<substr> runs a subset"
	@echo "  check      run every CI check in order: lint, build, test, cross"
	@echo "  lint       zig fmt, ruff, shellcheck, header/vendored parity, pin agreement"
	@echo "  check-header  assert src/mss.h matches the export table and struct layouts per -Dmss-version"
	@echo "  check-versions  assert every -Dmss-version is parity-swept or declared unswept"
	@echo "  cross      cross-compile the shipped x86-windows DLL"
	@echo "  format     apply zig fmt and ruff format"
	@echo "  parity     diff every -Dmss-version export table against its reference DLL"
	@echo "  clean      remove zig-out and .zig-cache"
	@echo "  help       show this message"
