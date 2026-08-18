# Windhawk Mod Workspace

A development workspace for [Windhawk](https://windhawk.net/) mods that lets you write a mod as
**multiple files** — headers, shared utilities, a real `README.md`, a real `settings.yaml` — and
still ship the single self-contained `.wh.cpp` Windhawk requires.

Compiler errors and `Wh_Log` output point at the file you were actually editing, not at a generated
blob. Press one key in your editor and the mod is bundled, compiled, installed and hot-reloaded.

---

## Why this exists

Windhawk compiles **exactly one translation unit per mod** and gives it **no include path**. A mod
therefore has to *ship* as one file. It does not have to be *written* as one.

There is a second problem. A mod's metadata, documentation and settings schema all live inline at
the top of the source, as comments:

```cpp
// ==WindhawkMod==            // @id / @version / @include / ...
// ==WindhawkModReadme==      /* several hundred lines of markdown */
// ==WindhawkModSettings==    /* several hundred lines of YAML */
```

Which means your editor greys out the first few hundred lines as dead comment text, GitHub renders
none of the markdown, no YAML or JSON tooling engages, and the C++ you came to work on starts
several screens down.

And a third: Windhawk's own `C:\ProgramData\Windhawk\ModsSource` is ACL'd `BUILTIN\Users:
ReadAndExecute`, so it cannot be edited by a normal editor at all.

This workspace inverts all three. Your repo is the source of truth, mods are folders, and a build
step flattens each one into the single file Windhawk wants. `ModsSource` becomes a *build output*.

```
mods/my-mod/mod.json          →  // ==WindhawkMod==          ┐
mods/my-mod/README.md         →  // ==WindhawkModReadme==    ├→  build/my-mod.wh.cpp  →  Windhawk
mods/my-mod/settings.yaml     →  // ==WindhawkModSettings==  │
mods/my-mod/src/main.wh.cpp   →  the C++, includes inlined   ┘
```

---

## Requirements

| | |
| --- | --- |
| **Windows** | 10 or 11 |
| **[Windhawk](https://windhawk.net/)** | installed; `windhawk-cli.exe` ships with it |
| **PowerShell 7+** | `winget install Microsoft.PowerShell` — Windows PowerShell 5.1 will not work |
| **`cpp-bundler.exe`** | vendored at [`tools/cpp-bundler.exe`](tools/) — see below |
| *(optional)* **VS Code / Cursor** | for the one-key build tasks and clangd IntelliSense |

### About `tools/cpp-bundler.exe`

The include-inlining is done by `cpp-bundler`, a small standalone tool written for this workspace by me.
It is committed here so a clone builds with no extra setup, but it is **an unsigned binary**, so
verify it rather than trusting it:

```powershell
(Get-FileHash .\tools\cpp-bundler.exe -Algorithm SHA256).Hash
# 24C8F17C664FCB27B7C4BBF4B61DAEED40D3A6110BB3FB11C3B707682364D578
```

| | |
| --- | --- |
| Version | 0.1.0 |
| Size | 990,208 bytes |
| Author | Tampered Reality (the author of this repo) |
| Purpose | Inlines quoted `#include`s into one file, emitting `#line` directives |
| Source Code | [cpp-bundler](https://github.com/GabrielHoy/cpp-bundler) |

It is looked up in this order, so you are free to put it elsewhere:

1. `$env:WH_BUNDLER` (full path to the executable)
2. `tools/cpp-bundler.exe`
3. `build/cpp-bundler.exe`
4. `cpp-bundler.exe` at the repo root
5. anywhere on `PATH`

### Finding your Windhawk install

The build scripts locate `windhawk-cli.exe` automatically, in this order, taking the first candidate
that actually contains the executable:

1. `$env:WINDHAWK_HOME`
2. `HKLM\SOFTWARE\Windhawk` → `install_dir` *(and the `WOW6432Node` view — Windhawk's installer is
   32-bit, so on x64 this is where it really lands)*
3. the `Uninstall\Windhawk` entry's `InstallLocation`, both registry views
4. `%ProgramFiles%\Windhawk` and `%ProgramFiles(x86)%\Windhawk`

So a non-default or non-`C:` install works with no configuration. If yours somehow isn't found:

```powershell
$env:WINDHAWK_HOME = 'D:\Apps\Windhawk'
```

> **Note**
> Editor integration is *not* auto-detected — `.vscode/settings.json` points clangd at
> `C:\Program Files\Windhawk\Compiler\bin\clangd.exe` and `compile_flags.txt` hardcodes the matching
> include path. Both are plain config; edit them if your install lives elsewhere. This affects
> IntelliSense only, never the build.

---

## Quick start

```powershell
git clone https://github.com/GabrielHoy/WindhawkUtilities.git
cd WindhawkUtilities

# 1. Make a mod folder
New-Item -ItemType Directory mods\my-mod\src -Force

# 2. Put a normal Windhawk mod source at mods\my-mod\src\main.wh.cpp
#    (paste one from Windhawk, or start from scratch)

# 3. Lift its metadata / readme / settings out into real files
.\scripts\wh-extract-blocks.ps1 my-mod

# 4. Build, compile, install, hot-reload
.\scripts\wh-install.ps1 my-mod
```

Step 4 prompts for UAC (see [The build daemon](#the-build-daemon) for why, and how to stop it
asking every time). After it succeeds the mod is live in Windhawk under the id `local@my-mod`.

From an editor, open any file in the mod and press **Ctrl+Shift+B**.

---

## Layout

```
mods/<name>/mod.json        optional; becomes the ==WindhawkMod== metadata block
mods/<name>/README.md       optional; becomes the ==WindhawkModReadme== block
mods/<name>/settings.yaml   optional; becomes the ==WindhawkModSettings== block
mods/<name>/src/            the C++: main.wh.cpp entry point + any headers beside it

shared/                     header-only utilities usable by every mod
schemas/                    JSON Schema for mod.json
scripts/                    the build scripts (see below)
tools/                      cpp-bundler.exe
build/                      generated bundles — never edit these, they are regenerated
```

Configuration sits at the mod root; C++ sits in `src/`. `src/main.wh.cpp` is the entry point, though
a flat `mods/<name>/main.wh.cpp` is also accepted — that is the shape files arrive in from
`ModsSource` — with `src/` winning if both somehow exist.

**The folder name is the mod's identity.** It names the `build/` output and is what the scripts
accept as a target.

> **Important**
> Windhawk installs any mod built from a file under the id `local@<@id>`. So a folder whose `@id` is
> `foo` installs as **`local@foo`** — a *fork* that sits alongside the catalogue's `foo` and leaves
> it untouched. That is how you fork a published mod: copy it in, edit, build. `wh-install.ps1`
> warns when it detects this.

---

## Splitting a mod across files

Write ordinary quoted includes and they get inlined:

```cpp
// mods/my-mod/src/main.wh.cpp
#include "animation.hpp"          // beside main.wh.cpp
#include "shared/Easing.hpp"      // from the repo-wide shared/ folder
#include <windows.h>              // left alone — Windhawk's compiler resolves it
```

Search paths are `src/`, the mod root, `shared/`, and the repo root (so `"shared/Foo.hpp"` works).
Angle-bracket includes are deliberately **not** resolved — they are passed through as directives for
Windhawk's compiler.

### Constraints that bite

- Each header is spliced **exactly once**, tracked by the bundler rather than the preprocessor.
  `#pragma once` is advisory here, and an X-macro header intended for repeated inclusion will
  silently expand only once.
- It is a text scanner: an `#include` inside `#if 0` is still consumed.
- An unresolvable quoted include is a **hard error** at bundle time. This is deliberate — a typo
  fails here rather than as a baffling diagnostic about a header Windhawk was never going to find.
- **Nothing may precede the `// ==WindhawkMod==` block** in `main.wh.cpp`.
- `shared/` headers must be self-contained and use `inline` / `static` / templates. Nothing tracks
  reverse dependencies, so after editing a `shared/` header, rebuild each mod that uses it.

---

## Metadata, readme and settings as real files

`wh-extract-blocks.ps1` migrates a conventional single-file mod into this layout:

| Inline block | becomes | and you get |
| --- | --- | --- |
| `// ==WindhawkMod==` | `mod.json` | JSON Schema completion, hover docs, enum validation |
| `// ==WindhawkModReadme==` | `README.md` | renders on GitHub, real markdown tooling |
| `// ==WindhawkModSettings==` | `settings.yaml` | YAML highlighting, folding, validation |

```powershell
.\scripts\wh-extract-blocks.ps1 my-mod -WhatIf     # preview, change nothing
.\scripts\wh-extract-blocks.ps1 my-mod             # do it
```

The bundler splices all three back in at build time, so **what Windhawk compiles is unchanged**. A
fully migrated `main.wh.cpp` has no header blocks at all and opens straight onto C++.

`mod.json` is read as **JSONC** (`//` comments are allowed) and validated against
`schemas/windhawk-mod.schema.json`. Repeatable fields (`include`, `exclude`, `architecture`) are
always arrays; locale-suffixed fields (`@name:zh-CN`) group under `localized`; unrecognised keys pass
through untouched, so a field Windhawk adds tomorrow is never dropped. Schema violations **warn**
rather than fail the build — your editor already flags them live and Windhawk validates again at
install, so a schema lagging behind Windhawk must never be able to block you.

A few things worth knowing:

- The extraction is **content-preserving, not byte-preserving**. Blank padding inside `/* */`
  wrappers is dropped and the metadata block is re-sorted into canonical order with values
  re-aligned. Verify by bundling before and after and diffing — only the build date, `#line` numbers
  and metadata whitespace should move.
- A `*/` inside `README.md` or `settings.yaml` is a **hard error** at bundle time. C has no escape
  for a nested block-comment terminator, so it would close the comment early and spill into the
  compiler.
- If a mod has *both* an external file and the matching inline block, the file wins and the inline
  block is dropped with a warning. Delete the inline one.
- Text *between* blocks is source, not scaffolding — a licence notice sitting between
  `==/WindhawkMod==` and the readme is preserved verbatim.

---

## Commands

```powershell
.\scripts\wh-install.ps1 my-mod                    # bundle + compile + install
.\scripts\wh-install.ps1 .\mods\my-mod\src\main.wh.cpp   # equivalent
.\scripts\wh-amalgamate.ps1 my-mod                 # bundle only — no UAC, no compile
.\scripts\wh-extract-blocks.ps1 my-mod             # migrate inline blocks into files
.\scripts\wh-daemon.ps1 -Status | -Stop            # the elevated build daemon
```

Every script accepts a **mod name, a mod folder, or any file inside one** — so an editor can pass
the currently-open file and the enclosing mod is derived by walking up to `mods/`. A file belonging
to no mod (a `shared/` header) rebuilds whichever mod was built last, recorded in `build/.last-mod`.

**`wh-install.ps1`**

| Flag | Effect |
| --- | --- |
| `-Enable` / `-Disabled` | force the mod on/off after install |
| `-Arch x64\|arm64\|all` | override target architectures |
| `-NoBundle` | install a `.wh.cpp` verbatim, skipping bundling |
| `-NoDaemon` | prompt for this build instead of using the daemon |
| `-NoElevate` | skip UAC (for an already-elevated shell) |

The default **preserves** the mod's current enabled/disabled state. This matters: a bare
`windhawk-cli mod install --file` defaults to *enabled* and would silently switch a disabled mod
back on. Runtime settings values survive a rebuild.

**`wh-amalgamate.ps1`** additionally takes `-OutDir` and `-NoLineDirectives`.
**`wh-extract-blocks.ps1`** takes `-All`, `-Block Metadata|Readme|Settings`, `-Force`, and `-WhatIf`.

### Editor tasks

`.vscode/tasks.json` provides *Build current mod* (Ctrl+Shift+B), *force enable*, *build by name*,
*bundle only*, *extract header blocks*, *daemon status/stop*, *list installed mods*, and *pull new
sources from `ModsSource`*. The problem matcher resolves clicks into `mods/`, not `build/`.

---

## The build daemon

`windhawk-cli` runs the bundled clang **in-process as the calling user**, so it needs Administrator
rights to write the built DLLs — which means a UAC prompt on every single build. The daemon replaces
that with **one prompt per session**: the first build starts an elevated helper, and every build
after it is quiet.

It is automatic. Your first build prompts, prints `==> daemon ready`, and carries on. `-NoDaemon`
opts a single build out.

```powershell
.\scripts\wh-daemon.ps1 -Status    # up? since when?
.\scripts\wh-daemon.ps1 -Stop      # close the window
```

Windows offers no way to pre-authorise one binary or hash for elevation — there is no `sudoers`
equivalent, and the only auto-elevation is for Microsoft-signed binaries manifested
`autoElevate=true` inside trusted system directories. A long-lived elevated helper is the honest
version of what is being asked for.

### ⚠️ What it costs — read this before using it

**While the daemon is running, any process running as you can queue a build without a consent
prompt.** That is a local privilege escalation. It is *inherent*, not an implementation flaw: the
elevated step compiles source from a directory you can write to unelevated, and installs the result
as a DLL that Windhawk injects into other processes. No amount of request validation closes that —
an attacker who can write `mods/` or `build/` is already inside the trust boundary.

The daemon does validate requests (the bundle must sit under `build/`, must be `.wh.cpp`, the arch
must be on a whitelist, and requests carry structured fields rather than a command line, so one can
only ever mean *"install this bundle"*) — but that is **hygiene against accidents, not a security
boundary.** Do not mistake it for one.

What *is* bounded is the window. The daemon registers nothing, survives no reboot, holds no
persistent state, and exits after `-IdleMinutes` of quiet (**default 240**). Run `-Stop` when you
finish working and the window closes. A scheduled task would remove the prompt permanently instead;
that trade was considered and rejected.

If you would rather not accept this at all, pass `-NoDaemon` and take the UAC prompt per build — or
raise the friction deliberately by lowering `-IdleMinutes`.

### How it works

Requests travel over a **file queue** in `build/.ipc`, not a named pipe, because of integrity
levels. A pipe created by an elevated (High IL) process carries a High mandatory label, and the
default `NO_WRITE_UP` policy stops a Medium IL client from writing to it — exactly the direction
requests need to travel. Working around that means hand-building a security descriptor with a
lowered SACL label, which .NET's `PipeSecurity` does not reliably round-trip.

So every file in a transaction is created by the *unelevated* client and carries a Medium label.
Writing *down* from High is always permitted, so the daemon fills them in, and the client owns them
and cleans them up. Three files keyed on one GUID:

| File | Written by | Meaning |
| --- | --- | --- |
| `<id>.log` | daemon appends | build output; the client tails it live |
| `<id>.done` | daemon, last | the exit code — non-empty means finished |
| `<id>.req` | client, last, by atomic rename | the request itself |

Ordering matters: response files are created first so the daemon never observes a request it cannot
answer. Liveness is a lock file the client creates and the daemon holds with `FileShare.None`; a
sharing violation means a daemon is up. That doubles as the single-instance guard — a second daemon
cannot take the lock and exits. Stopping is cooperative for the same reason requests are: the
daemon's *process object* is High IL too, so an unelevated `Stop-Process` would be a write-up and
gets denied.

---

## Diagnostics

The generated bundle carries `#line` directives, so clang blames the original file and line rather
than somewhere in `build/`. `mods/my-mod/src/animation.hpp:212:9` is what lands in the Problems
panel, and clicking it opens the header. `Wh_Log` expands `__LINE__`, so runtime log output is
remapped the same way.

Two fixups make that work:

1. `#line` directives are emitted with raw Windows paths — `#line 2 "\\?\C:\repo\util.hpp"` — which
   is broken inside a C string literal, since `\U` starts a universal character name and `\r\t\a`
   are control characters. Paths are rewritten to forward slashes with the `\\?\` prefix stripped.
2. The bundler's first `#line` directive lands above line 1, which would push the
   `// ==WindhawkMod==` block off the top of the file and stop Windhawk recognising the mod. The
   header run is hoisted back to byte 0 and the directive re-emitted beneath it with a corrected
   line number.

Anything outside a `#line` mapping is anchored to `<stdin>`, because `windhawk-cli` pipes the source
to the compiler. Those line and column numbers are correct against the bundle, so the scripts rewrite
`<stdin>` to the bundle path to make them clickable.

---

## IntelliSense

`compile_flags.txt` mirrors Windhawk's real compile — C++23, `x86_64-w64-mingw32`, `-DWH_MOD
-DWH_EDITING`, force-included `windhawk_api.h` — and `.vscode/settings.json` points clangd at
**Windhawk's own bundled clangd** (`C:\Program Files\Windhawk\Compiler\bin\clangd.exe`) so the
editor resolves the exact mingw sysroot the build uses. Keep those flags in sync with Windhawk's, or
the editor and the build will disagree.

`build/` is excluded from search and from clangd's background index (`build/.clangd`) — bundles
contain a copy of every symbol in `mods/` and `shared/`, so indexing them would offer the generated
file as often as the real source.

`.clang-format` is Windhawk's Chromium base with local overrides. `CommentPragmas` is pinned so
clang-format will not reflow `@metadata` lines — don't relax it.

---

## Caveats

- **Windows-only, PowerShell 7+.** No cross-platform story; the elevation and integrity-level work is
  Win32-specific by nature.
- **No test suite.** `wh-extract-blocks.ps1` rewrites `main.wh.cpp` in place — use `-WhatIf` first,
  and keep your work in git.
- **`ModsSource` copies drift.** Windhawk's updater rewrites mods in `ModsSource` without touching
  this repo. The *pull* task imports only mods missing here and **skips** existing ones, so
  re-pulling cannot quietly clobber a mod you have split across files. To take a fresh upstream copy
  of a mod you already have, delete its folder first.
- **Never edit files in `build/`.** They are regenerated on every build.

---

## License

[MIT](LICENSE) © Gabriel Hoy (Tampered Reality).

Windhawk itself is by [Ramen Software](https://github.com/ramensoftware/windhawk) and is not affiliated
with this project. Any mod you place in `mods/` retains its own author and license.
