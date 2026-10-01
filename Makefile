.PHONY: test check shellcheck build

test:
	./tests/run-tests.sh

shellcheck:
	nix shell nixpkgs#shellcheck --command \
	  shellcheck -x -P lib:tests bin/airlock lib/*.sh tests/*.sh

check:
	nix flake check

build:
	nix build
