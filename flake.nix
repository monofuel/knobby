{
  description = "knobby development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        name = "knobby-dev";

        buildInputs = with pkgs; [
          nim
          nimble
          alsa-utils
          pulseaudio
        ];

        shellHook = ''
          echo "knobby dev shell ready"
          echo "  nimble test                        - run unit tests"
          echo "  nim r examples/midi_monitor.nim    - monitor Arduino MIDI"
          echo "  nim r examples/audio_outputs.nim   - list audio output streams"
        '';
      };
    };
}
