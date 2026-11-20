# chg generic adapter

The adapter behind `.chg/adapter.toml` with `kind = "generic"` (contract v1,
[docs/adapter-contract.md](../../docs/adapter-contract.md)): a repo with no build and no unit-test
framework of its own, whose tests are suites (one script each) and whose repo already knows which
suites a change can reach. claude-config is the first: about 112 bash canary suites under
`hooks/tests/`, selected by its own `bin/affected-suites.sh` from `.chg/suites.toml` (chg#20).

It is one stdlib Python script (3.8+). The repo supplies the two parts only it knows, as shell
commands on the manifest's lines:

    scripts/install-generic-adapter.sh      # once per machine: ~/.local/share/chg/generic

| Command | What it does |
|---|---|
| `snapshot [--cmd <sh>]` | Nothing, or `<sh>`. A generic repo has no build, so its manifest may leave `artifacts` out. |
| `static --base <sha> [--check <name>=<sh>]...` | Each check under `sh -c`, concurrently, with `CHG_BASE` and `CHG_HEAD` set; a non-zero exit is a failure carrying the last 40 lines of its output. |
| `affected --base <sha> --select <sh> --suite-dir <dir>` | Writes the changed paths (against the base, untracked included, renames split) to a file, runs `<sh>` with `CHG_CHANGED` naming it and `CHG_BASE` set, and maps each name it prints to `<dir>/<name>`. |
| `run --tests <list> --runner <sh> --suite-dir <dir> [--result <re>] [--skip <word>]...` | Runs `<sh>` once with `CHG_SUITES` holding the listed suites' names, space-separated, and reads one result per suite from its output. |
| `shard --of <n> --index <i> --runner <sh> --suite-dir <dir> --suite-glob <g> [--result <re>] [--skip <word>]...` | The suites in `<dir>` matching `<g>`, sorted, every `n`th from the `i`th, run as `run` does. |

## The selector and the runner

The selector prints the word `ALL`, or suite names (or `<dir>/`-prefixed paths) one per line. It
fails closed: `ALL`, a non-zero exit, an empty selection, a name with no file under `--suite-dir`,
an unknown base, a changed `read_at_runtime` path (this adapter records no reads), or a bad
argument line each print `{"mode":"all"}` with the reason, so `chg` runs every suite.

The runner prints a line per suite that `--result` matches. The default reads
`PASS <name> (12s)`, `FAIL <name> (rc=1, 3s)` and `SKIP <name> (1s, ...)`, which is claude-config's
`bin/run-canaries.sh`; the seconds are the last `<N>s` in the parentheses. A different runner passes
its own regex with the named groups `status`, `name`, and optionally `secs`. `PASS`/`OK` pass and any
other word fails, unless the manifest names it with `--skip WORD`: then it is the contract's `skip`,
which **fails no verdict**. So name a word with `--skip` only when the runner prints it for a suite
the gate itself accepts (run-canaries' SKIP: passed, with an allowed skipped layer), never for a
suite it could not start: a run in which every selected suite printed that word is a pass, as it
is for the gate (run-canaries.sh passes one on purpose). A listed suite the runner never reports is an `error`, and a runner that exits non-zero
while no suite failed adds an `error` result, so a crash after the last suite is never a pass.

`always_all` is applied by `chg` before the adapter runs, as for every kind.

## Tests

    python3 adapters/generic/test/test_adapter.py
    CHG_BIN=target/debug/chg python3 adapters/generic/test/test_adapter.py

They build a throwaway git repo with a fake selector and runner. With `CHG_BIN` set they also
validate its manifest and drive `chg adapter exec affected` and `shard`. CI sets it.
