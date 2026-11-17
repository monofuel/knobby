{
  description = "knobby development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      runtimeTools = with pkgs; [ alsa-utils pulseaudio wmctrl curl systemd procps ];
      graphics = with pkgs; [ xorg.libX11 xorg.libXcursor xorg.libXrandr xorg.libXi
        xorg.libXinerama libGL dbus mesa ];
      pins = builtins.filter (line: line != "")
        (pkgs.lib.splitString "\n" (builtins.readFile ./gui/app/nimby.lock));
      dependencies = map (line:
        let fields = pkgs.lib.splitString " " line;
            revision = builtins.elemAt fields 3;
            repo = pkgs.lib.removeSuffix "/" (pkgs.lib.removePrefix "https://github.com/" (builtins.elemAt fields 2));
            hashes = builtins.fromJSON (builtins.readFile ./nix/dependency-hashes.json);
        in { name = builtins.elemAt fields 0;
          src = pkgs.fetchzip { url = "https://codeload.github.com/${repo}/tar.gz/${revision}";
            hash = hashes.${revision}; }; }
      ) pins;
      dependencyConfig = pkgs.lib.concatMapStringsSep "\n"
        (dep: ''--path:"${dep.src}/src"'') dependencies;
      knobby = pkgs.stdenv.mkDerivation {
        pname = "knobby";
        version = "0.1.0";
        src = self;
        nativeBuildInputs = with pkgs; [ nim nimble makeWrapper xorg.xorgserver dbus systemd openbox ];
        buildInputs = graphics;
        buildPhase = ''
          runHook preBuild
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME" gui/app/dist
          cat > gui/nim.cfg <<'CONFIG'
          # Managed by Nimby
          ${dependencyConfig}
          CONFIG
          nim c -o:knobby-daemon src/knobby.nim
          nim c -o:gui/app/dist/knobby_gui gui/app/src/knobby_gui.nim
          runHook postBuild
        '';
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          for test in tests/test*.nim; do nim r "$test"; done
          export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (graphics ++ [pkgs.xorg.libXtst])}"
          export LIBGL_DRIVERS_PATH="${pkgs.mesa}/lib/dri"
          export DBUS_SESSION_CONF="${pkgs.dbus}/share/dbus-1/session.conf"
          export FONTCONFIG_FILE="${pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; }}"
          sh gui/app/tools/smoke.sh
          runHook postCheck
        '';
        installPhase = ''
          mkdir -p "$out/bin" "$out/libexec" "$out/share/knobby"
          cp knobby-daemon "$out/libexec/knobby"
          cp gui/app/dist/knobby_gui "$out/libexec/knobby-gui"
          makeWrapper "$out/libexec/knobby" "$out/bin/knobby" \
            --prefix PATH : "${pkgs.lib.makeBinPath runtimeTools}"
          makeWrapper "$out/libexec/knobby-gui" "$out/bin/knobby-gui" \
            --prefix PATH : "${pkgs.lib.makeBinPath [pkgs.systemd]}" \
            --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath graphics}"
          cp docs/knobby.service docs/knobby-gui.service docs/knobby-gui.desktop "$out/share/knobby/"
          mkdir -p "$out/share/licenses/knobby"
          cp gui/app/assets/DejaVu-LICENSE.txt "$out/share/licenses/knobby/"
          ${pkgs.lib.concatMapStringsSep "\n" (dep: ''
            mkdir -p "$out/share/licenses/${dep.name}"
            for license in ${dep.src}/LICENSE* ${dep.src}/COPYING*; do
              if [ -f "$license" ]; then cp "$license" "$out/share/licenses/${dep.name}/"; fi
            done
          '') dependencies}
        '';
      };
    in {
      packages.${system} = { inherit knobby; default = knobby; };
      checks.${system}.knobby = knobby;
      devShells.${system}.default = pkgs.mkShell {
        name = "knobby-dev";

        buildInputs = with pkgs; [
          nim
          nimble
          alsa-utils
          pulseaudio
          wmctrl
          curl
          systemd
          xorg.libX11
          xorg.libXcursor
          xorg.libXrandr
          xorg.libXi
          xorg.libXinerama
          xorg.libXtst
          libGL
          dbus
          xorg.xorgserver
          mesa
          openbox
        ];

        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
          xorg.libX11 xorg.libXcursor xorg.libXrandr xorg.libXi
          xorg.libXinerama xorg.libXtst libGL dbus
        ]);

        shellHook = ''
          echo "knobby dev shell ready"
          echo "  nimble test                        - run unit tests"
          echo "  nim r examples/midi_monitor.nim    - monitor Arduino MIDI"
          echo "  nim r examples/audio_outputs.nim   - list audio output streams"
        '';
      };
    };
}
