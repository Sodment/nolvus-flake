{
  description = "Nolvus Dashboard (Linux .NET 9 port) — fully packaged, with a working CefGlue/CEF browser on NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Upstream source, pinned & auto-locked in flake.lock (no manual src hash needed).
    nolvus-src = {
      url = "github:sableeyed/NolvusDashboard/819ff0f6bf78e90e3ccdd01d665af72a9cb1d519";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, nolvus-src }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true; # protontricks/steam deps
        };
        lib = pkgs.lib;

        dotnet-runtime = pkgs.dotnet-runtime_9;
        dotnet-sdk = pkgs.dotnet-sdk_9;

        # Split-out packages that were renamed across nixpkgs versions.
        gbm = pkgs.libgbm or pkgs.mesa;
        udevLib = pkgs.systemdLibs or pkgs.systemd;

        # ------------------------------------------------------------------
        # Runtime library closure needed by BOTH Avalonia (Skia/HarfBuzz + X11)
        # and CEF (libcef.so + its render/network subprocess dlopen'ing NSS,
        # GTK and the X11 stack). Missing these is why the SSO page crashed the
        # CEF subprocess. gtk3 drags in glib/atk/pango/cairo/gdk-pixbuf/at-spi2.
        # ------------------------------------------------------------------
        cefRuntimeLibs = (with pkgs; [
          gtk3
          nss
          nspr
          libdrm
          mesa            # GL drivers (llvmpipe/dri)
          libglvnd        # libGL / libEGL dispatch
          libxkbcommon
          alsa-lib
          cups.lib
          dbus
          expat
          fontconfig
          freetype
          # X11 pieces Avalonia + CEF touch directly
          xorg.libX11
          xorg.libICE
          xorg.libSM
          xorg.libXi
          xorg.libXext
          xorg.libXcursor
          xorg.libXrandr
          xorg.libXrender
          xorg.libXfixes
          xorg.libXdamage
          xorg.libXcomposite
          xorg.libXtst
          xorg.libXScrnSaver
          xorg.libXinerama
          xorg.libxcb
          xorg.libxshmfence
          # misc
          zlib
          libnotify
          # .NET 9 native deps
          icu
          openssl
          krb5
          libunwind
          stdenv.cc.cc.lib # libstdc++ / libgcc_s
          cacert
        ]) ++ [ gbm udevLib ]
          ++ lib.optionals (pkgs ? lttng-ust) [ pkgs.lttng-ust ];

        # External tools the dashboard shells out to (upstream README + wget in
        # Nolvus.Package/Files/ModFile.cs).
        runtimeTools = (with pkgs; [
          protontricks
          winetricks
          xorg.xrandr
          xwayland
          wget
          coreutils
          which
          bashInteractive
        ]);

        fontPkgs = with pkgs; [ dejavu_fonts liberation_ttf ];
        fontsConf = pkgs.makeFontsConf { fontDirectories = fontPkgs; };

        # ------------------------------------------------------------------
        # Reproducible build of the patched source.
        # ------------------------------------------------------------------
        nolvus-dashboard = pkgs.buildDotnetModule {
          pname = "nolvus-dashboard";
          version = "3.8.8.1";
          src = nolvus-src;

          projectFile = "Nolvus.Dashboard/Nolvus.Dashboard.csproj";
          nugetDeps = ./deps.nix; # regenerate once: nix run .#nolvus-dashboard.fetch-deps

          inherit dotnet-sdk dotnet-runtime;

          # RID-specific, framework-dependent (matches csproj) so the CEF / Skia /
          # HarfBuzz runtimes/linux-x64/native assets land in the output.
          runtimeId = "linux-x64";
          selfContainedBuild = false;

          executables = [ "NolvusDashboard" ];

          # No source patch is required: persistence is handled by staging the
          # app into a writable dir at launch (see launcher below), and the CEF
          # sandbox is already disabled upstream. Left as an extension point.
          patches = [ ];

          meta = with lib; {
            description = "Nolvus Skyrim modlist installer (Linux port)";
            homepage = "https://github.com/sableeyed/NolvusDashboard";
            license = licenses.gpl3Only;
            platforms = [ "x86_64-linux" ];
          };
        };

        # ------------------------------------------------------------------
        # Launcher: stage the (read-only) store build into a writable per-user
        # dir so the app's portable-folder model (ini, Instances, Cache, lib,
        # reports, logs — all under BaseDirectory) works, then run it there.
        # ------------------------------------------------------------------
        launcher = pkgs.writeShellScript "nolvus-launch" ''
          set -euo pipefail

          export DOTNET_ROOT=${dotnet-runtime}
          export DOTNET_CLI_TELEMETRY_OPTOUT=1
          export DOTNET_NOLOGO=1
          # CA trust for .NET (OpenSSL) HTTPS/WSS to nexusmods.com + CEF.
          export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
          export SSL_CERT_DIR=${pkgs.cacert}/etc/ssl/certs
          # Fonts for Avalonia/Skia + QuestPDF report generation.
          export FONTCONFIG_FILE=${fontsConf}

          APPDIR="''${XDG_DATA_HOME:-$HOME/.local/share}/nolvus-dashboard"
          STORE_APP="${nolvus-dashboard}/lib/nolvus-dashboard"

          if [ "''${1:-}" = "--reset" ]; then
            echo "Resetting $APPDIR ..."
            rm -rf "$APPDIR"
            shift
          fi

          mkdir -p "$APPDIR"
          STAMP="$APPDIR/.nix-store-source"

          # (Re)install immutable app files when the store build changed, while
          # preserving user data (ini, Instances, Cache, reports, downloaded lib).
          if [ ! -f "$STAMP" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "${nolvus-dashboard}" ]; then
            echo "Staging Nolvus Dashboard into $APPDIR ..."
            # cp -r (not -a): don't try to preserve root ownership from the
            # store (that would warn/fail under `set -e`). chmod makes the
            # staged tree writable while the apphost keeps its execute bit.
            cp -r "$STORE_APP"/. "$APPDIR"/
            chmod -R u+w "$APPDIR"
            printf '%s' "${nolvus-dashboard}" > "$STAMP"
          fi

          cd "$APPDIR"
          # Extra CEF/Chromium flags can be passed through, e.g.
          #   nix run . -- --disable-gpu --no-zygote
          exec ./NolvusDashboard "$@"
        '';

        # FHS sandbox that actually provides the libraries at runtime.
        wrapped = pkgs.buildFHSEnv {
          name = "nolvus-dashboard";
          targetPkgs = _: cefRuntimeLibs ++ runtimeTools ++ fontPkgs
            ++ [ dotnet-runtime ];
          runScript = "${launcher}";
        };

        # Optional: a REAL FHS shell (unlike `nix develop` on buildFHSEnv.env)
        # for hacking on a source checkout: `nix run .#dev` then `dotnet run ...`.
        fhsDev = pkgs.buildFHSEnv {
          name = "nolvus-dev";
          targetPkgs = _: cefRuntimeLibs ++ runtimeTools ++ fontPkgs
            ++ [ dotnet-sdk pkgs.git ];
          runScript = "bash";
          profile = ''
            export DOTNET_CLI_TELEMETRY_OPTOUT=1
            export DOTNET_NOLOGO=1
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export FONTCONFIG_FILE=${fontsConf}
            if command -v dotnet >/dev/null 2>&1; then
              export DOTNET_ROOT="$(dirname "$(readlink -f "$(command -v dotnet)")")"
            fi
            echo "FHS dev shell — run: dotnet run --project Nolvus.Dashboard/Nolvus.Dashboard.csproj"
          '';
        };
      in
      {
        packages = {
          default = wrapped;
          inherit nolvus-dashboard; # exposes .passthru.fetch-deps
        };

        apps = {
          default = {
            type = "app";
            program = "${wrapped}/bin/nolvus-dashboard";
          };
          dev = {
            type = "app";
            program = "${fhsDev}/bin/nolvus-dev";
          };
        };
      });
}
