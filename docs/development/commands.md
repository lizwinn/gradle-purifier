# Commands

All from the repository root.

```zsh
# Every check in the sandbox (each Gradle build takes up to 2 GB)
nix flake check --max-jobs 2

# The checks of every system, evaluated without building
nix flake check --all-systems --no-build

# Interactive-mode and publish tests (needs Nix; gives Gradle no network)
tests/interactive.sh

# Renew the lockfiles of the fixtures (needs the network)
tests/relock-fixtures.sh            # the stale ones
tests/relock-fixtures.sh --relock   # all of them

# The command
nix build '.#gradle-purifier'
nix run '.#gradle-purifier' -- lock

nix fmt
```

After a change to the recorder or to what the init script does in a lock
run, renew the fixture lockfiles with `--relock`: their build definitions
are unchanged, so a plain run keeps them.

## CI

`.github/workflows/check.yml` runs the flake checks, the evaluation for
every system and the interactive tests on every push to main and every
pull request.
