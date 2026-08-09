# Nolvus Dashboard on NixOS — fully packaged flake with a working CEF/SSO browser

A self-contained Nix flake for [`sableeyed/NolvusDashboard`](https://github.com/sableeyed/NolvusDashboard)
(the native **.NET 9 + Avalonia** Linux port). It builds the app and runs it inside
an FHS sandbox so the embedded **CefGlue / CEF** browser works and the **NexusMods
SSO login stops crashing**. No `nix develop` needed — `nix run` launches it.

## Why it crashed

The browser is OutSystems **CefGlue** (`CefGlue.Common 120.6099.211`), whose native
Chromium binaries ship as normal NuGet redist packages. On NixOS they can't find the
libraries they `dlopen`. The window opens on `about:blank` (in-process), but the
moment it loads the real `nexusmods.com/sso` page CEF spawns its render + network
subprocesses, which need **NSS** (TLS) and the **GTK/X11** stack — those fail and the
subprocess crashes. `NoSandbox = true` is already set upstream, so the fix is to give
the process an **FHS layout** containing those libs.

Two extra NixOS pitfalls this flake also handles:
- **Read-only store vs. portable-folder app.** Upstream keeps *everything* writable
  (settings `.ini`, `Instances/`, `Cache/`, `lib/`, `reports/`, logs) next to the
  executable (`BaseDirectory`). On the Nix store that's read-only, so the app would
  crash/lose data. The launcher stages the app into `$XDG_DATA_HOME/nolvus-dashboard`
  (default `~/.local/share/nolvus-dashboard`) and runs it there.
- **CA certs + fonts.** `SSL_CERT_FILE` (so .NET's HTTPS/WSS to Nexus works) and a
  generated `FONTCONFIG_FILE` are set for the sandbox.

## Requirements

- A graphical session (X11, or Wayland with XWayland).
- Steam installed and configured on the host (per upstream README).
- Flakes enabled (`experimental-features = nix-command flakes`).

## Setup (one-time)

The only manual step is generating the NuGet lock (the sandboxed build has no
network). From this flake directory, on your NixOS machine:

```bash
nix build .#nolvus-dashboard.fetch-deps -o fetch-deps
./fetch-deps "$PWD/deps.json"
```

That restores every NuGet package (including the CefGlue CEF redist) and writes
`deps.json` (a JSON lockfile) with pinned hashes. The source itself is pinned in
`flake.lock` automatically — no source hash to fill in.

> Two gotchas, both handled by the command above:
> - Do **not** use `nix run .#nolvus-dashboard.fetch-deps`. The `fetch-deps` output
>   is a single script file (not a package with a `bin/`), so `nix run` fails with
>   `unable to execute …/bin/nolvus-dashboard; Not a directory`.
> - Current nixpkgs generates a **JSON** lockfile. Writing it to `deps.nix` and
>   importing it as Nix gives `syntax error, unexpected ':'` at `"pname": "Avalonia"`.
>   Use `deps.json` (this flake sets `nugetDeps = ./deps.json`).

## Run

```bash
nix run .            # build (first time) + launch the dashboard
# or
nix build .#default  # -> ./result/bin/nolvus-dashboard
```

On first launch it stages the app into `~/.local/share/nolvus-dashboard` (this is
where your settings and installed instances live). Click **“Nexus SSO
Authentication”** — the CEF window should now load the live Nexus page and finish;
the button turns to **“Authentication successful.”**

Useful launcher options (passed straight through to the app / CEF):

```bash
nix run . -- --reset                       # wipe the staged app dir + user data, re-stage
nix run . -- --disable-gpu --no-zygote     # software rendering fallback if CEF still crashes
nix run . -- --enable-logging=stderr --v=1 # verbose CEF logs for diagnosis
```

## If the CEF window still crashes

CEF reads flags from the process command line, so **no rebuild is needed** — try:

```bash
nix run . -- --disable-gpu --disable-gpu-compositing --no-zygote
```

`--disable-gpu` forces SwiftShader software rendering and resolves most remaining
GPU/driver-mismatch crashes on varied NixOS GPU setups. To bake it in permanently,
add the flags to the `exec ./NolvusDashboard "$@"` line in `flake.nix`’s launcher.

To see exactly which library fails (run from inside the staged dir):

```bash
nix run .#dev        # real FHS shell
ldd ~/.local/share/nolvus-dashboard/libcef.so | grep 'not found'
```

## What this covers

- **Fixes:** NexusMods SSO login in the embedded browser; ENB downloads from
  `enbdev.com` and non-premium manual Nexus downloads (all use the same CEF browser);
  settings/instance persistence on the read-only store.
- **Unaffected:** premium Nexus mod downloads use the API directly, never the browser.
- **No source patch:** persistence is solved by staging to a writable dir; the CEF
  sandbox is already disabled upstream. The `patches = [ ]` list in `flake.nix` is the
  place to add C# changes later (e.g. baking in CEF flags) if you ever want them.

## Files

| File        | Purpose                                                                 |
|-------------|-------------------------------------------------------------------------|
| `flake.nix` | Packaged build (`buildDotnetModule`) + FHS launcher; `nix run .` / `.#dev`. |
| `deps.json` | NuGet lock (JSON) — regenerate with the `fetch-deps` command above.      |
| `README.md` | This file.                                                              |

## Notes / limitations

- I could not test the build on this machine (authored on Windows, no Nix). The one
  command that needs network — `fetch-deps` — must run on your NixOS box. Everything
  else is pinned/locked.
- `dotnet-sdk_9` / `dotnet-runtime_9` are on `nixos-unstable` (pinned by this flake).
- The Updater component (a Windows `.exe`) isn’t used on Linux; it’s ignored here.
