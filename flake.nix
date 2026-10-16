{
  description = "airlock — isolated, virtualized coding-agent workspaces";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # The microVM airlock launches. `flake = false` on purpose: all airlock needs
  # is the pinned revision to build a flake reference from, and locking it as a
  # flake would drag its inputs (microvm.nix, another nixpkgs) into our lock for
  # nothing. Bump it with `nix flake update claude-microvm`.
  inputs.claude-microvm = {
    #url = "github:systemstart/claude-microvm";
    url = "github:devinrsmith/claude-microvm?ref=feat/registry-mirrors";
    flake = false;
  };

  # What `airlock registry import` reads registries.conf through: a CLI around
  # the library Podman, Buildah, Skopeo and CRI-O read it with. Built on our
  # nixpkgs, like everything else in the stack.
  inputs.registries-conf = {
    url = "github:devinrsmith/registries-conf";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, claude-microvm, registries-conf }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});

      # What `airlock version` reports as the commit. A dirty worktree has no
      # rev, only a dirtyRev ("<sha>-dirty"); a source with no git at all, such
      # as a path: reference, has neither.
      airlockCommit = self.rev or self.dirtyRev or "unknown";

      # The flake reference an installed build bakes in for an input, rebuilt
      # whole from flake.lock — owner and repository included, so a fork named
      # in the inputs above stays a fork rather than becoming the upstream
      # repository at the fork's revision. The input itself carries its
      # revision but not its owner, hence the lock. When the two disagree the
      # input was overridden at build time (`--override-input`, or a consumer's
      # `follows`) and the lock no longer describes it, so name its source in
      # the store instead: exact, if less readable.
      lock = builtins.fromJSON (builtins.readFile ./flake.lock);
      lockedRef = name: input:
        let
          l = lock.nodes.${lock.nodes.${lock.root}.inputs.${name}}.locked;
        in
          if (l.rev or null) != (input.rev or null) then "path:${input.outPath}"
          else if builtins.elem l.type [ "github" "gitlab" "sourcehut" ] then
            "${l.type}:${l.owner}/${l.repo}/${l.rev}" + nixpkgs.lib.optionalString (l ? host) "?host=${l.host}"
          else if l.type == "git" then "git+${l.url}?rev=${l.rev}"
          else "path:${input.outPath}";

      registriesConf = system: registries-conf.packages.${system}.default;
    in
    {
      packages = forSystems (pkgs: {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.airlock;

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
            # AIRLOCK_SUBSTRATE is a flake reference, not a path: it comes from
            # our lock (see lockedRef), so an installed airlock launches exactly
            # the microVM this build was locked against, and `nix flake update`
            # is how that moves.
            #
            # AIRLOCK_NIXPKGS is the one nixpkgs for the whole stack: the
            # registry builds from it, and the default substrate is launched
            # with `--override-input nixpkgs` set to it, so the microVM does not
            # run on whatever nixpkgs claude-microvm's own lock happens to hold.
            #
            # AIRLOCK_REGISTRIES_CONF is the registries.conf reader `registry
            # import` asks, and jq is what reads its answers.
            wrapProgram $out/bin/airlock \
              --set AIRLOCK_LIB $out/lib \
              --set AIRLOCK_SUBSTRATE ${pkgs.lib.escapeShellArg (lockedRef "claude-microvm" claude-microvm)} \
              --set AIRLOCK_NIXPKGS ${pkgs.lib.escapeShellArg (lockedRef "nixpkgs" nixpkgs)} \
              --set AIRLOCK_COMMIT ${pkgs.lib.escapeShellArg airlockCommit} \
              --set AIRLOCK_REGISTRIES_CONF ${registriesConf pkgs.stdenv.hostPlatform.system}/bin/registries-conf \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.coreutils pkgs.gawk pkgs.jq ]}
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
            # confirmation would go untested in CI. registries-conf
            # and jq are for tests/test-registry-import.sh, which otherwise
            # skips.
            nativeBuildInputs = [
              pkgs.bash pkgs.git pkgs.gawk pkgs.coreutils pkgs.util-linux pkgs.jq
              (registriesConf pkgs.stdenv.hostPlatform.system)
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
