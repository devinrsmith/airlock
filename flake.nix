{
  description = "airlock — isolated, virtualized coding-agent workspaces";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # The microVM airlock launches. `flake = false` on purpose: all airlock needs
  # is the pinned revision to build a flake reference from, and locking it as a
  # flake would drag its inputs (microvm.nix, another nixpkgs) into our lock for
  # nothing. Bump it with `nix flake update claude-microvm`.
  inputs.claude-microvm = {
    url = "github:systemstart/claude-microvm";
    flake = false;
  };

  outputs = { self, nixpkgs, claude-microvm }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});

      # What `airlock version` reports as the commit. A dirty worktree has no
      # rev, only a dirtyRev ("<sha>-dirty"); a source with no git at all, such
      # as a path: reference, has neither.
      airlockCommit = self.rev or self.dirtyRev or "unknown";
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

            # A source checkout finds lib/ alongside bin/; an installed build is
            # told where it went, so the layout need not survive the store.
            #
            # AIRLOCK_SUBSTRATE is a flake reference, not a path: the revision
            # comes from our lock, so an installed airlock launches exactly the
            # microVM this build was locked against, and `nix flake update`
            # is how that moves.
            wrapProgram $out/bin/airlock \
              --set AIRLOCK_LIB $out/lib \
              --set AIRLOCK_SUBSTRATE "github:systemstart/claude-microvm/${claude-microvm.rev}" \
              --set AIRLOCK_COMMIT ${pkgs.lib.escapeShellArg airlockCommit} \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.coreutils pkgs.gawk ]}
            runHook postInstall
          '';
          meta = {
            description = "Isolated, virtualized coding-agent workspaces";
            homepage = "https://github.com/devinrsmith/airlock";
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
            # util-linux provides script(1) for the pty cases in
            # tests/test-rm.sh: without it they skip, and the typed-name
            # confirmation would go untested in CI.
            nativeBuildInputs = [
              pkgs.bash pkgs.git pkgs.gawk pkgs.coreutils pkgs.util-linux
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
