# NuGet dependency lock for the reproducible (packaged) build.
#
# This is a PLACEHOLDER. It is only needed for `nix build .#default` /
# `nix run .#default`. The recommended `nix develop` / `nix run .#dev` path does
# NOT use this file.
#
# Regenerate it on your NixOS machine (needs network) with:
#
#     nix build .#nolvus-dashboard.fetch-deps -o fetch-deps
#     ./fetch-deps "$PWD/deps.nix"
#
# (Do NOT use `nix run .#nolvus-dashboard.fetch-deps` — the fetch-deps output is a
#  single script file, so nix run fails with "Not a directory".)
#
# That command restores every NuGet package (including the CefGlue CEF redist
# packages) and rewrites this file with pinned hashes.
{ fetchNuGet }: [ ]
