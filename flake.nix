{
  description = "Ressac — Julia live coding env + SuperDirt audio backend";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # SuperCollider with sc3-plugins (FFT helpers SuperDirt needs).
        sc = pkgs.supercollider-with-sc3-plugins;

        # SuperDirt and its sclang dependency, pinned. SuperDirt is not in
        # nixpkgs as a Quark, so we vendor the sources directly and point
        # sclang at them via a per-project sclang_conf.yaml.
        superdirt = pkgs.fetchFromGitHub {
          owner = "musikinformatik";
          repo  = "SuperDirt";
          rev   = "7e245e87f8f08a3d55e33a360bc97912f32fe69b"; # v1.7.3
          hash  = "sha256-FFBJBlUY6jttEEkn3qldS8z2qoncSyDITUy+x/6l5F8=";
        };

        vowel = pkgs.fetchFromGitHub {
          owner = "supercollider-quarks";
          repo  = "Vowel";
          rev   = "ab59caa870201ecf2604b3efdd2196e21a8b5446";
          hash  = "sha256-zfF6cvAGDNYWYsE8dOIo38b+dIymd17Pexg0HiPFbxM=";
        };

        # ~250 MB of WAVs. fetchFromGitHub will only do it once and cache.
        dirt-samples = pkgs.fetchFromGitHub {
          owner = "tidalcycles";
          repo  = "Dirt-Samples";
          rev   = "c74fc80f8db8038f6a33648ffef5ac00a07ad402";
          hash  = "sha256-OzVvy/L6jfEgGx3dMdhe/PkfMAWVV0HQ9wGy500++fw=";
        };

        # Project-local sclang config: include the two class quarks. Lives in
        # the Nix store, so we never touch ~/.local/share/SuperCollider.
        sclangConf = pkgs.writeText "ressac-sclang_conf.yaml" ''
          includePaths:
            - ${superdirt}
            - ${vowel}
          excludePaths: []
          postInlineWarnings: false
        '';

        # Launcher binary. Sets DIRT_SAMPLES_PATH for the .scd, points sclang
        # at the project config, and routes JACK calls through PipeWire's
        # libjack shim (works on stock NixOS desktops without extra config).
        # Stay in the foreground; Ctrl+C stops scsynth + SuperDirt cleanly.
        start-superdirt = pkgs.writeShellApplication {
          name = "start-superdirt";
          runtimeInputs = [ sc pkgs.pipewire.jack ];
          text = ''
            export DIRT_SAMPLES_PATH=${dirt-samples}
            SCRIPT="''${RESSAC_ROOT:-$PWD}/scripts/superdirt-startup.scd"
            if [ ! -f "$SCRIPT" ]; then
              echo "Cannot find $SCRIPT — run this from the Ressac repo root." >&2
              exit 1
            fi
            # pw-jack wraps sclang so scsynth's JACK client talks to PipeWire.
            exec pw-jack sclang -l ${sclangConf} "$SCRIPT"
          '';
        };
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.julia-bin
            sc
            start-superdirt
            pkgs.just
            pkgs.git
          ];

          shellHook = ''
            export RESSAC_ROOT="$PWD"
            export DIRT_SAMPLES_PATH=${dirt-samples}
            cat <<'BANNER'
            Ressac dev shell ready. Audio stack pinned via Nix — no runtime install.

                just                # list recipes
                just audio          # boot scsynth + SuperDirt on UDP 57120
                just live           # the Ressac TUI
                just test           # full test suite

            BANNER
          '';
        };

        apps.start-superdirt = {
          type = "app";
          program = "${start-superdirt}/bin/start-superdirt";
        };

        apps.default = self.apps.${system}.start-superdirt;
      });
}
