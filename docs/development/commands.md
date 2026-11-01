# Commands

All from the repository root.

```zsh
# Every check in the sandbox (each Gradle build takes up to 2 GB)
nix flake check --max-jobs 2

# The checks of every system, evaluated without building
nix flake check --all-systems --no-build

# conformance-offline: prefetch, ./gradlew offline, publish, the IDE
# import and the error cases (needs Nix and the network)
tests/offline.sh

# conformance-update (needs the network)
tests/update.sh

# Renew the lockfiles of the fixtures (needs the network)
tests/relock-fixtures.sh            # the stale ones
tests/relock-fixtures.sh --relock   # all of them

# Write the lockfiles of the conformance checks again, after a relock of
# the Java library fixture
tests/conformance/generate.sh

# The command
nix build '.#gradle-purifier'
nix run '.#gradle-purifier' -- lock

nix fmt
```

After a change to the recorder or to what the init script does in a lock
run, renew the fixture lockfiles with `--relock`, because their build
definitions are unchanged and a plain run keeps them. Then run
`tests/conformance/generate.sh`; evaluation fails until the conformance
lockfiles match the new Java library lockfile.

## CI

`.github/workflows/check.yml` runs on every push to main and every pull
request, on x86_64-linux and aarch64-linux. The `check` job runs the
flake checks and the evaluation for every system. The jobs
`conformance-relock`, `conformance-rebuild`, `conformance-offline` and
`conformance-update` run the conformance checks that need the network or
Nix outside the sandbox.
