# NuGet dependency lock for the reproducible (packaged) build.
#
# This is a PLACEHOLDER. It is only needed for `nix build .#default` /
# `nix run .#default`. The recommended `nix develop` / `nix run .#dev` path does
# NOT use this file.
#
# Regenerate it on your NixOS machine (needs network) with:
#
#     nix run .#nolvus-dashboard.fetch-deps
#
# That command restores every NuGet package (including the CefGlue CEF redist
# packages) and rewrites this file with pinned hashes.
{ fetchNuGet }: [ ]
