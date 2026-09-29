# Contributing

## Setup

Five tools, the first four version-pinned in the tree:

| Tool | Version | Declared in | Install (any equivalent works) |
|------|---------|-------------|---------------------------------|
| Zig | 0.16.0 | `.minimum_zig_version` in `build.zig.zon` | <https://ziglang.org/download/> |
| uv | 0.12.19 | `UV_VERSION` in the `Makefile` | <https://docs.astral.sh/uv/getting-started/installation/> |
| ruff | 0.16.4 | `RUFF_VERSION` in the `Makefile` | `uv tool install ruff==0.16.4` |
| yamllint | 1.38.0 | `YAMLLINT_VERSION` in the `Makefile` | `uv tool install yamllint==1.38.0` |
| shellcheck | any recent | required by `make lint` | your package manager |

`uv` is only the installer for the two pinned linters (CI brings it in the same
way), so nothing else in the tree needs it.

`make` reads the Zig version out of `build.zig.zon` and refuses to build on
any other one; `make check-pins` (part of `make lint`) fails when a workflow
types a tool version instead of reading it out of the Makefile, when the
Makefile and `build.zig.zon` disagree, and when the C warning set in
`scripts/check_header.py` drifts from `c_flags` in `build.zig`. Nothing else is
fetched: every dependency is a vendored header under `deps/`, verified by
`make check-vendored` against `deps/SHA256SUMS`, and listed for consumers in
`SBOM.cdx.json`, which `make check-sbom` regenerates and compares.

`make parity` is the one exception. It diffs each `-Dmss-version` build against
a reference DLL under `references/`, which is copyrighted and not distributed,
so it never runs in CI and is not part of `make check`. It also needs one
third-party Python package, declared in `scripts/requirements.txt`. `uv pip
install` refuses to run outside a virtual environment, so the environment comes
first; the `source` line is what puts the venv's `python3` on PATH, which is the
one `make parity` and `scripts/check_all_versions.sh` resolve:

```bash
uv venv
source .venv/bin/activate
uv pip install -r scripts/requirements.txt
```

Deactivate with `deactivate` when you are done. `.venv/` is gitignored.

Optional: a `test_media/` directory holding `test.wav`, `test.mid`, and
`test.sf2`. The build installs it next to the test binaries and the fixtures
that need it skip themselves when it is absent, so a clone without it still
builds and tests green.

## The loop

```bash
make build                # zig build
make test FILTER=redbook  # one test, by substring of its name
make test                 # the whole suite (minutes)
make sanitize             # the same suite with the C undefined-behaviour sanitizer
make harnesses            # the native plugin harness in tests/
make check                # everything CI runs, in CI's order
```

`make help` lists every target. A filtered run is the edit-test loop: it
rebuilds only the test artifacts and skips the rest of the suite, and a filter
that matches no test name is refused rather than reported as a pass. Test output
is quiet by default; set `OPENMILES_DEBUG=1` to get the engine trace and the
`openmiles.log` it writes.

An unfiltered `make test` ends with a `failed command: ... --listen=-` line and
still exits 0 whenever a test wrote to stderr. Zig 0.16.0 emits it for a run
that passed (reproducible in an empty project whose only test prints a line),
so the exit status and the `N/N tests passed` summary the recipe asks for are
what decide the outcome, not that line.

`make sanitize` is `zig build test -Dsanitize`: it instruments every C
translation unit (the bindings, the vendored headers translate-C pulls in, the
`tests/*.c` harnesses) with the undefined-behaviour sanitizer and forces Debug.
Zig's own safety checks are already on in the Debug build `make test` uses; this
adds the UB the C code and the vendored third-party code can hit. It takes
noticeably longer than a plain run, so it is its own CI step rather than part of
`make test`.

## Before you push

`make check` runs `make lint`, `make build`, `make test`, `make sanitize`,
`make harnesses`, and the x86-windows cross-compile, which is what
`.github/workflows/ci.yml` runs on Ubuntu. CI additionally runs the build and
tests on Windows; nothing in the library is Linux-only, but a change that only
builds on one host shows up there rather than locally.

The library builds and tests on any host Zig supports, through `zig build` and
`zig build test`. The `make` targets and the two `scripts/*.sh` gates need more:
a POSIX shell (`sh`, GNU make, `sed`, `command -v`), plus `shellcheck` and a
Python 3 interpreter named either `python3` or `python`. On Windows that means
MSYS2, Cygwin, or Git Bash, none of which the Windows runner has, which is why
CI runs `make lint` on Ubuntu only. The gates themselves are ordinary Python and
are invoked as `$(PYTHON) scripts/<name>.py`, so they run unchanged under a
Windows Python; only their launcher is platform-specific.

`make lint` is `zig fmt --check`, `ruff check`, `ruff format --check`,
`shellcheck scripts/*.sh`, `shellcheck` over every `run:` block in `.github`,
`yamllint .github`, plus the header-parity, example-compile, version-sweep,
vendored-checksum, SBOM-drift, threat-model-reference, release-archive, and
pin-agreement checks. `make format` applies the two formatters.

## The harnesses in `tests/`

`make test` runs the Zig test binaries only. A change needs a Zig test; a
harness in `tests/` covers ground the Zig binaries cannot and does not replace
one. Of the five, `native_rib_test` is the only one the host runs, and it has a
target:

```bash
make harnesses            # rebuilds, then runs it from zig-out/bin
```

It is in `make check` and in CI, and it is the only coverage of the plugin
`dlopen` path: the test binaries link musl statically, where `dlopen` is a
stub. It finds `plugins/mock.asi` next to its own executable, so it has to run
from `zig-out/bin`, which is what the recipe does. `make cross` installs a PE
plugin at that same path, so the target rebuilds first; run it in that order
and nothing is left over from a Windows build.

The other four, `play_test`, `midi_test`, `full_suite`, and `rib_test`, are
Windows harnesses that `LoadLibrary` the built `mss32.dll` and call its
exports. Nothing runs them, here or in CI, so a change to them is verified by
hand on Windows, from `zig-out/bin` so each finds `mss32.dll` next to itself:

```
zig build
cd zig-out/bin && full_suite.exe
```

`play_test`, `midi_test`, and `full_suite` take the fixture paths as arguments
(`test_media/test.wav`, `test_media/test.mid`, `test_media/test.sf2`) and
report the missing file when it is absent. On Linux they build but cannot run:
`deps/windows_stub.h` resolves no export, so every call is a null pointer.

## What a change is expected to carry

- A changelog entry under `## [Unreleased]` in `CHANGELOG.md`, in the
  Keep-a-Changelog section for its kind.
- Tests. A bug fix gets the failing test first; the Zig tests live in the
  `test` blocks of the module they cover, with the module-level suites in
  `src/test_root.zig` and `src/engine_test_root.zig`. The harnesses in `tests/`
  are a separate thing, described below.
- An entry in `docs/API_STATUS.md` when a function's implementation status
  changes, and the relevant table in `README.md` when a coverage claim does.

## Generated and vendored files

`deps/` is vendored upstream source, pinned by `deps/SHA256SUMS`; the update
procedure is in `deps/README.md`. `src/mss.h` is checked against the export
table in `src/main.zig` for every `-Dmss-version` by `make check-header`, so
adding an export means declaring it in the header in the same change.
