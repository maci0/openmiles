# Security policy

## What this project is

OpenMiles is a drop-in `mss32.dll` replacement for the Miles Sound System. It is
a library loaded into a game process. It opens no network port, has no server
component, and handles no user accounts or personal data. Its input surface is
the data files a game opens through it (audio, MIDI/XMIDI, DLS, MSS soundbanks)
and the `.asi`/`.m3d`/`.flt` plugin DLLs it loads from the game's directory.

The full model, including the current risk ranking, is in
[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

## Supported versions

Only the current default branch build is supported. There are no LTS or
long-term-support branches in this repository.

## Reporting a vulnerability

Open a private security advisory on the repository's GitHub page. Please
include the game and data files involved, the build flags used
(`-Dmss-version`, `-Doptimize`, target), and the steps to reproduce.

No disclosure deadline or embargo policy is defined by this project yet.

## What is in scope

- Memory safety problems reached from a data file the game opens (soundbank,
  event bytecode, XMIDI/MIDI, MP3, OGG, WAV, FLAC, DLS).
- The temporary-file handling in `AIL_open_ASI_provider`, which writes a
  caller-supplied PE image to `%TEMP%` before loading it.
- Anything reachable from `AIL_startup`'s scan of the game directory for
  plugin files.

## What is out of scope

- Loading an unsigned `.asi`/`.m3d`/`.flt` plugin from the game directory. The
  original MSS behaves the same way, and the plugin is native code the user
  deliberately installed. Keep the game directory writable only by the user.
- A bug in miniaudio, TinySoundFont, or `tml.h`; report those upstream.
- Crafted arguments passed to the exports by a buggy host game. The C ABI
  cannot validate a caller's pointers, and a caller inside the process already
  has more authority than the library.
