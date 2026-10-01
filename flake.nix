{
  description = "airlock — isolated, virtualized coding-agent workspaces";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      packages = forSystems (pkgs: {
        default = self.packages.${pkgs.system}.airlock;

        airlock = pkgs.stdenv.mkDerivation {
          pname = "airlock";
          version = "0.1.0-dev";
          src = ./.;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          dontBuild = true;
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/lib
            cp lib/*.sh $out/lib/
            install -m755 bin/airlock $out/bin/airlock

            # The vendored substrate is a git submodule, and flakes leave
            # submodules out of the source tree unless the reference asks for
            # them (`?submodules=1`). Install it when it is there; when it is
            # not, airlock says so at launch rather than quietly reaching for
            # github.
            substrateArgs=()
            if [ -f substrate/claude-microvm/flake.nix ]; then
              mkdir -p $out/substrate
              cp -r substrate/claude-microvm $out/substrate/
              substrateArgs=(--set AIRLOCK_SUBSTRATE $out/substrate/claude-microvm)
            else
              echo "note: building without the vendored substrate (no ?submodules=1)" >&2
            fi

            # A source checkout finds lib/ alongside bin/; an installed build is
            # told where it went, so the layout need not survive the store.
            wrapProgram $out/bin/airlock \
              --set AIRLOCK_LIB $out/lib \
              ''${substrateArgs[@]+"''${substrateArgs[@]}"} \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.coreutils pkgs.gawk ]}
            runHook postInstall
          '';
          meta = {
            description = "Isolated, virtualized coding-agent workspaces";
            mainProgram = "airlock";
            platforms = pkgs.lib.platforms.linux;
          };
        };
      });

      checks = forSystems (pkgs: {
        # Every check here runs without a VM. Booting one stays a manual smoke
        # test: GitHub's runners give no KVM (§8).
        tests = pkgs.runCommand "airlock-tests"
          {
            # util-linux and less are for the pty case in tests/test-review.sh:
            # without them it skips, and the regression it guards (a pager
            # swallowing `review --accept`) would go unnoticed in CI.
            nativeBuildInputs = [
              pkgs.bash pkgs.git pkgs.gawk pkgs.coreutils pkgs.util-linux pkgs.less
            ];
          } ''
          cp -r ${./.} src && chmod -R u+w src
          export HOME=$TMPDIR
          # The source keeps `#!/usr/bin/env bash` because the guest it targets
          # has no /bin/bash; the build sandbox has no /usr/bin/env, so patch
          # here rather than weakening the shebang.
          patchShebangs src/bin src/tests
          bash src/tests/run-tests.sh
          touch $out
        '';

        shellcheck = pkgs.runCommand "airlock-shellcheck"
          {
            nativeBuildInputs = [ pkgs.shellcheck ];
          } ''
          cp -r ${./.} src && chmod -R u+w src
          cd src
          shellcheck -x -P lib:tests bin/airlock lib/*.sh tests/*.sh
          touch $out
        '';
      });

      devShells = forSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.git pkgs.shellcheck pkgs.bash ];
        };
      });
    };
}
