# Contributing

## Setup

Four tools, the first three version-pinned in the tree:

| Tool | Version | Declared in | Install (any equivalent works) |
|------|---------|-------------|---------------------------------|
| Zig | 0.16.0 | `.minimum_zig_version` in `build.zig.zon` | <https://ziglang.org/download/> |
| ruff | 0.16.4 | `RUFF_VERSION` in the `Makefile` | `uv tool install ruff==0.16.4` |
| yamllint | 1.38.0 | `YAMLLINT_VERSION` in the `Makefile` | `uv tool install yamllint==1.38.0` |
| shellcheck | any recent | required by `make lint` | your package manager |

`make` reads the Zig version out of `build.zig.zon` and refuses to build on
any other one; `make check-pins` (part of `make lint`) fails when the Makefile,
`ci.yml`, and `build.zig.zon` disagree, and when the C warning set in
`scripts/check_header.py` drifts from `c_flags` in `build.zig`. Nothing else is
fetched: every dependency is a vendored header under `deps/`, verified by
`make check-vendored` against `deps/SHA256SUMS`, and listed for consumers in
`SBOM.cdx.json`, which `make check-sbom` regenerates and compares.

`make parity` is the one exception. It diffs each `-Dmss-version` build against
a reference DLL under `references/`, which is copyrighted and not distributed,
so it never runs in CI and is not part of `make check`. It also needs one
third-party Python package, declared in `scripts/requirements.txt`:

```bash
uv pip install -r scripts/requirements.txt
```

Optional: a `test_media/` directory holding `test.wav`, `test.mid`, and
`test.sf2`. The build installs it next to the test binaries and the fixtures
that need it skip themselves when it is absent, so a clone without it still
builds and tests green.

## The loop

```bash
make build                # zig build
make test FILTER=redbook  # one test, by substring of its name
make test                 # the whole suite (minutes)
make check                # everything CI runs, in CI's order
```

`make help` lists every target. A filtered run is the edit-test loop: it
rebuilds only the test artifacts and skips the rest of the suite, and a filter
that matches no test name is refused rather than reported as a pass. Test output
is quiet by default; set `OPENMILES_DEBUG=1` to get the engine trace and the
`openmiles.log` it writes.

## Before you push

`make check` runs `make lint`, `make build`, `make test`, and the
x86-windows cross-compile, which is what `.github/workflows/ci.yml` runs on
Ubuntu. CI additionally runs the build and tests on Windows; nothing in the
library is Linux-only, but a change that only builds on one host shows up there
rather than locally.

The library builds and tests on any host Zig supports, through `zig build` and
`zig build test`. The `make` targets and the two `scripts/*.sh` gates need more:
a POSIX shell (`sh`, GNU make, `sed`, `command -v`), plus `shellcheck` and a
Python 3 interpreter named either `python3` or `python`. On Windows that means
MSYS2, Cygwin, or Git Bash, none of which the Windows runner has, which is why
CI runs `make lint` on Ubuntu only. The gates themselves are ordinary Python and
are invoked as `$(PYTHON) scripts/<name>.py`, so they run unchanged under a
Windows Python; only their launcher is platform-specific.

`make lint` is `zig fmt --check`, `ruff check`, `ruff format --check`,
`shellcheck scripts/*.sh`, `yamllint .github/workflows`, plus the header-parity,
version-sweep, vendored-checksum, threat-model-reference, and pin-agreement
checks. `make format` applies the two formatters.

## What a change is expected to carry

- A changelog entry under `## [Unreleased]` in `CHANGELOG.md`, in the
  Keep-a-Changelog section for its kind.
- Tests. A bug fix gets the failing test first; the Zig tests live in the
  `test` blocks of the module they cover, with the module-level suites in
  `src/test_root.zig` and `src/engine_test_root.zig`, and the C harnesses in
  `tests/`.
- An entry in `docs/API_STATUS.md` when a function's implementation status
  changes, and the relevant table in `README.md` when a coverage claim does.

## Generated and vendored files

`deps/` is vendored upstream source, pinned by `deps/SHA256SUMS`; the update
procedure is in `deps/README.md`. `src/mss.h` is checked against the export
table in `src/main.zig` for every `-Dmss-version` by `make check-header`, so
adding an export means declaring it in the header in the same change.
