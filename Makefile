.PHONY: all build test check clean lint format check-header check-versions check-pins check-python check-threat-model check-toolchain check-host-tools check-parity-tools check-vendored cross parity help

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

# The threat model names a file:line and an anchor for every control it claims
# exists. Edits move those lines, so a stale reference is a mitigation claim
# nobody re-verified, which reads the same as a real one. Assert the anchors
# still sit where the model says they do.
check-threat-model:
	./scripts/check_threat_model_refs.py

check-python:
	@command -v ruff >/dev/null 2>&1 || { echo "error: ruff $(RUFF_VERSION) not found on PATH" >&2; exit 1; }
	@v=`ruff --version | cut -d' ' -f2`; [ "$$v" = "$(RUFF_VERSION)" ] || { echo "error: ruff $(RUFF_VERSION) required, found $$v" >&2; exit 1; }
	ruff check .
	ruff format --check .

check-host-tools:
	@command -v shellcheck >/dev/null 2>&1 || { echo "error: shellcheck not found on PATH; 'make lint' shellchecks scripts/*.sh" >&2; exit 1; }
	@command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found on PATH; the scripts/*.py gates need it" >&2; exit 1; }

# The parity sweep alone needs a third-party package. `make lint` deliberately
# does not depend on it, so CI and a contributor without the reference DLLs
# never have to install anything; `make parity` checks for it here instead of
# failing later on an import.
check-parity-tools:
	@python3 -c 'import pefile' 2>/dev/null || { echo "error: pefile not found; uv pip install -r scripts/requirements-dev.txt" >&2; exit 1; }

lint: check-host-tools
	zig fmt --check .
	shellcheck scripts/*.sh
	./scripts/check_header.py
	./scripts/check_versions.py
	./scripts/check_vendored.py
	./scripts/check_threat_model_refs.py
	@$(MAKE) --no-print-directory check-python
	@$(MAKE) --no-print-directory check-pins

format:
	zig fmt .
	ruff format .

clean:
	rm -rf zig-out .zig-cache

# Per-version export-parity sweep; needs the reference DLLs under references/.
parity: check-parity-tools
	./scripts/check_all_versions.sh

help:
	@echo "Targets:"
	@echo "  build      build the library and the test binaries (zig build)"
	@echo "  test       run the test suite (zig build test); FILTER=<substr> runs a subset"
	@echo "  check      run every CI check in order: lint, build, test, cross"
	@echo "  lint       zig fmt, ruff, shellcheck, header/vendored parity, pin agreement"
	@echo "  check-header  assert src/mss.h matches the export table and struct layouts per -Dmss-version"
	@echo "  check-versions  assert every -Dmss-version is parity-swept or declared unswept"
	@echo "  check-threat-model  assert every file:line anchor in docs/THREAT_MODEL.md resolves"
	@echo "  cross      cross-compile the shipped x86-windows DLL"
	@echo "  format     apply zig fmt and ruff format"
	@echo "  parity     diff every -Dmss-version export table against its reference DLL (needs scripts/requirements-dev.txt)"
	@echo "  clean      remove zig-out and .zig-cache"
	@echo "  help       show this message"
