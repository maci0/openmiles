.PHONY: all build test check clean lint format check-header check-versions check-pins check-python check-yaml check-threat-model check-toolchain check-host-tools check-interpreter check-parity-tools check-vendored check-sbom cross parity sanitize help

# The one toolchain this project builds with. build.zig.zon carries
# .minimum_zig_version, but that is a floor, not the version the output was
# verified against; a stray zig on PATH would silently build anyway. Read the
# version from build.zig.zon so it is declared once: CI and the release
# workflow read the same field, and nothing has to be kept in sync by hand.
ZIG_VERSION := $(shell sed -n 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon)

# The gate interpreter, resolved rather than assumed: `python3` is the name on
# Linux and macOS, `python` the one a Windows install puts on PATH, and a
# shebang line is not honoured by every shell that can run make. The gates are
# invoked as `$(PYTHON) scripts/...` so one resolution covers every call site.
PYTHON := $(shell command -v python3 2>/dev/null || command -v python 2>/dev/null)

# Exported so the `test` recipe reads FILTER from the environment rather than
# splicing a caller's argument into the recipe text.
export FILTER

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
#
# A filter that matches no test name is a typo, not a green run, so it is
# checked here: zig reports a zero-test run as success, which is how a
# contributor ends up believing a fix is covered when nothing ran. FILTER goes
# through the environment, not into the recipe text. The names are read with
# find + grep rather than a GNU-only `grep --include` scan, and matched
# with the shell's own substring test, so the check does not depend on a grep
# that BSD (macOS) does not ship.
test: check-toolchain
	@if [ -n "$$FILTER" ]; then \
	  names=$$(find src -name '*.zig' -exec grep -hoE 'test "[^"]*"' {} +); \
	  case "$$names" in \
	    *"$$FILTER"*) ;; \
	    *) echo "error: no test name in src/ contains '$$FILTER'; run 'make test' with no FILTER" >&2; exit 1 ;; \
	  esac; \
	fi
	zig build test $(if $(FILTER),-Dtest-filter=$(FILTER))

# The undefined-behaviour sanitizer build. Separate from `test` on purpose: it
# rebuilds every C translation unit with instrumentation, so it is minutes
# slower than a plain run and CI runs it as its own job rather than making every
# pull request pay for it. FILTER works here too. Zig's own safety checks are
# already on in the Debug build `test` uses; what this adds is UB in the C
# sources and the vendored headers translate-C pulls in, which is where the
# interpreter code in src/ actually lives.
sanitize: check-toolchain
	zig build test -Dsanitize $(if $(FILTER),-Dtest-filter=$(FILTER))

# Everything .github/workflows/ci.yml runs, in the same order, so a failure
# here is the same failure CI would give.
check: lint build test sanitize cross

# The shipped artifact. A build that only passes natively can still fail to
# link as a 32-bit stdcall DLL, so check what ships. Gated on the toolchain for
# the same reason `build` is: a stray zig would produce a cross-compiled DLL
# nobody compared against the references, and this is the output that ships.
cross: check-toolchain
	zig build -Dtarget=x86-windows -Doptimize=ReleaseFast

# Every gate under scripts/ needs an interpreter, and $(PYTHON) is resolved
# when make reads the makefile, so on a machine with neither name the recipe
# would run the script as a program and fail with the shell's own error (exit
# 127), naming neither the missing tool nor the fix. `make lint` catches this
# through check-host-tools; the individual targets are what a contributor runs
# while iterating, so they ask first. The message is the one the sibling
# preflights use.
check-interpreter:
	@[ -n "$(PYTHON)" ] || { echo "error: neither python3 nor python found on PATH; the scripts/*.py gates need one" >&2; exit 1; }

# src/mss.h declares the C surface; src/main.zig is the export table it must
# agree with, and src/root.zig the struct layouts, for every -Dmss-version.
# See scripts/check_header.py.
check-header: check-interpreter
	$(PYTHON) scripts/check_header.py

# Every -Dmss-version value must be swept against a reference DLL or declared
# unswept with a reason, and the three places that list the values must agree.
# See scripts/check_versions.py.
check-versions: check-interpreter
	$(PYTHON) scripts/check_versions.py

# deps/ holds vendored upstream headers, not package-manager downloads, so
# deps/SHA256SUMS is the only record of which bytes were reviewed.
check-vendored: check-interpreter
	$(PYTHON) scripts/check_vendored.py

# The CycloneDX inventory of the third-party code this release carries, derived
# from deps/README.md, deps/SHA256SUMS, scripts/requirements.txt, and
# build.zig.zon. It is checked, not written, here: a header swap or a pip bump
# that does not regenerate it fails the gate rather than publishing a stale
# inventory. See scripts/gen_sbom.py.
check-sbom: check-interpreter
	$(PYTHON) scripts/gen_sbom.py --check

# The gate scripts are the linter, so ruff checks them too: ruff.toml pins the
# rule set, and a script that crashes or stops reporting fails the gate
# silently. Pinned for the same reason as the zig above, so a newer local ruff
# cannot turn the tree red against a green CI.
RUFF_VERSION := 0.16.4

# Same reasoning for yamllint over the workflows. A workflow is the one file
# whose mistakes stay invisible until CI or a release is already running.
YAMLLINT_VERSION := 1.38.0

# The Zig, ruff, and yamllint pins live in the Makefile, ci.yml, and
# build.zig.zon; a stale one in CI installs the old tool and the gate quietly
# stops matching.
check-pins: check-interpreter
	$(PYTHON) scripts/check_toolchain_pins.py

# The threat model names a file:line and an anchor for every control it claims
# exists. Edits move those lines, so a stale reference is a mitigation claim
# nobody re-verified, which reads the same as a real one. Assert the anchors
# still sit where the model says they do.
check-threat-model: check-interpreter
	$(PYTHON) scripts/check_threat_model_refs.py

check-python:
	@command -v ruff >/dev/null 2>&1 || { echo "error: ruff $(RUFF_VERSION) not found on PATH" >&2; exit 1; }
	@v=`ruff --version | cut -d' ' -f2`; [ "$$v" = "$(RUFF_VERSION)" ] || { echo "error: ruff $(RUFF_VERSION) required, found $$v" >&2; exit 1; }
	ruff check .
	ruff format --check .

# .yamllint carries the rule set, so the gate reads the same file CI does.
check-yaml:
	@command -v yamllint >/dev/null 2>&1 || { echo "error: yamllint $(YAMLLINT_VERSION) not found on PATH; 'make lint' checks the workflows with it" >&2; exit 1; }
	@v=`yamllint --version | cut -d' ' -f2`; [ "$$v" = "$(YAMLLINT_VERSION)" ] || { echo "error: yamllint $(YAMLLINT_VERSION) required, found $$v" >&2; exit 1; }
	yamllint .github/workflows

check-host-tools:
	@command -v shellcheck >/dev/null 2>&1 || { echo "error: shellcheck not found on PATH; 'make lint' shellchecks scripts/*.sh" >&2; exit 1; }
	@command -v yamllint >/dev/null 2>&1 || { echo "error: yamllint $(YAMLLINT_VERSION) not found on PATH; 'make lint' checks .github/workflows with it" >&2; exit 1; }
	@[ -n "$(PYTHON)" ] || { echo "error: neither python3 nor python found on PATH; the scripts/*.py gates need one" >&2; exit 1; }

# The parity sweep alone needs a third-party package. `make lint` deliberately
# does not depend on it, so CI and a contributor without the reference DLLs
# never have to install anything; `make parity` checks for it here instead of
# failing later on an import.
check-parity-tools:
	@[ -n "$(PYTHON)" ] || { echo "error: neither python3 nor python found on PATH; the scripts/*.py gates need one" >&2; exit 1; }
	@$(PYTHON) -c 'import pefile' 2>/dev/null || { echo "error: pefile not found; uv pip install -r scripts/requirements.txt" >&2; exit 1; }

lint: check-host-tools
	zig fmt --check .
	shellcheck scripts/*.sh
	$(PYTHON) scripts/check_header.py
	$(PYTHON) scripts/check_versions.py
	$(PYTHON) scripts/check_vendored.py
	$(PYTHON) scripts/gen_sbom.py --check
	$(PYTHON) scripts/check_threat_model_refs.py
	@$(MAKE) --no-print-directory check-python
	@$(MAKE) --no-print-directory check-yaml
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
	@echo "Usage: make <target> [VAR=value ...]"
	@echo ""
	@echo "Targets:"
	@echo "  build      build the library and the test binaries (zig build)"
	@echo "  test       run the test suite (zig build test); FILTER=<substr> runs a subset"
	@echo "  sanitize   run the test suite with the C undefined-behaviour sanitizer (-Dsanitize)"
	@echo "  check      run every CI check in order: lint, build, test, sanitize, cross"
	@echo "  lint       zig fmt, ruff, shellcheck, yamllint, header/vendored parity, pin agreement"
	@echo "  format     apply zig fmt and ruff format"
	@echo "  cross      cross-compile the shipped x86-windows DLL"
	@echo "  parity     diff every -Dmss-version export table against its reference DLL (needs scripts/requirements.txt)"
	@echo "  clean      remove zig-out and .zig-cache"
	@echo "  help       show this message"
	@echo ""
	@echo "Individual checks (all run by lint):"
	@echo "  check-toolchain     assert zig on PATH is the pinned build.zig.zon version"
	@echo "  check-host-tools    assert shellcheck and a Python 3 interpreter are installed"
	@echo "  check-header        assert src/mss.h matches the export table and struct layouts per -Dmss-version"
	@echo "  check-versions      assert every -Dmss-version is parity-swept or declared unswept"
	@echo "  check-vendored      assert deps/ matches the digests in deps/SHA256SUMS, and that each vendored entry names its upstream commit"
	@echo "  check-sbom          assert SBOM.cdx.json matches the vendored deps and the declared pip pins"
	@echo "  check-threat-model  assert every file:line anchor in docs/THREAT_MODEL.md resolves"
	@echo "  check-python        assert ruff on PATH is the pinned version, then lint and format-check"
	@echo "  check-yaml          assert yamllint on PATH is the pinned version, then lint .github/workflows"
	@echo "  check-interpreter   assert a Python 3 interpreter is named python3 or python"
	@echo "  check-parity-tools  assert pefile is importable (only make parity needs it)"
	@echo "  check-pins          assert the zig and ruff pins agree across the tree"
	@echo ""
	@echo "These targets take no arguments, so 'make check-header --help' is make's own"
	@echo "help and the check does not run. The Python gates behind them print their own"
	@echo "usage on --help, as 'python3 scripts/check_header.py --help' ('python' where that"
	@echo "is the name on PATH; make resolves the same way, via \$$PYTHON)."
