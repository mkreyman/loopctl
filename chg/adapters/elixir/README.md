# chg Elixir adapter

The `mix chg.*` tasks behind a Mix project's `.chg/adapter.toml` (contract v1,
[docs/adapter-contract.md](../../docs/adapter-contract.md)). They ship as a Mix archive, so a
product repo needs no dependency and no `mix.lock` line:

    scripts/install-elixir-adapter.sh      # once per machine and Elixir version

A product then adds:

- `.chg/adapter.toml`, copied from [adapter.toml](adapter.toml) and its globs adjusted;
- `elixirc_options: [check_cwd: false]` in `project/0` of `mix.exs`. A workspace hydrated from
  a snapshot sits at a new path, and without this Mix recompiles every module because the
  manifest's cwd differs (design §3.5). Use the project option, not `mix compile --no-check-cwd`:
  `mix test` rejects that flag. `mix chg.snapshot` refuses to run without it.

| Task | Contract command | What it does |
|---|---|---|
| `mix chg.snapshot` | `snapshot` | `deps.get`, `compile` in dev and test, the dialyzer PLT (when dialyxir is a dependency), then `mix chg.refs`. Does nothing when HEAD, `mix.lock` and the toolchain match its marker. |
| `mix chg.refs` | (part of `snapshot`) | Compiles the test files without running them or starting the app, and records each one's module references in `_build/chg/test_refs.etf`. |
| `mix chg.affected --base <sha>` | `affected` | Test files referencing a module changed since `<sha>`, or any module that transitively references one, from Mix's compile manifest. |
| `mix chg.static --base <sha>` | `static` | `format --check-formatted` and `credo --strict` on the changed files, `compile --warnings-as-errors`, `dialyzer`. |
| `mix chg.run --tests <list>` | `run` | `mix test` on the listed paths, one result per test. |
| `mix chg.shard --of <n> --index <i>` | `shard` | One stable shard of the whole suite. |

## Why the selection does not use `mix test --stale --dry-run`

On Elixir 1.20.4, `--dry-run` turns `--stale` off (`Mix.Compilers.Test.require_and_run/3`:
`if stale and not dry_run`), so it lists every test. The stale manifest (`compile.test_stale`) is
also written only after a run with zero failures. So the adapter keeps its own reference cache,
built at snapshot time by `mix chg.refs`, and reads Mix's compile manifest for the module graph.
The dependent closure is the one `--stale` uses: compile, export and runtime references,
followed transitively.

A test file is selected when it changed since the base or since the snapshot, when it has no
recorded references (new, or it does not compile without `test_helper.exs`), or when it has a
compile or runtime reference to an affected module (the two `--stale` matches on). A changed path maps to modules through the sources that define
them, the sources that read it as an `@external_resource`, and, for a deleted source, the
snapshot's record of what it defined. A deleted source the snapshot does not know selects every
test. `always_all` is applied by `chg` before the adapter runs.

## Environment

`affected`, `static`, `run`, `shard` and `refs` work in `MIX_ENV=test`. Started in another env, a
task runs itself again under `MIX_ENV=test`. The manifest sets `MIX_ENV=test` so `chg` never
pays for the second VM. Mix 1.20 deprecated a task picking its own env, and a product should not
need a `def cli` entry for an archive's tasks.

`mix compile` prunes the code path to the project's own applications, which drops the archive's
ebin. Each task therefore loads all of its modules before it compiles, and `run` calls
`mix test` in the same VM so its formatter stays loaded.

## Tests

    mix test test/select_test.exs test/static_test.exs test/runner_test.exs test/snapshot_test.exs \
      test/chg_adapter_test.exs
    CHG_BIN=../../target/debug/chg mix test test/integration_test.exs

The integration test builds the archive, installs it into a private `MIX_ARCHIVES`, and drives
[fixtures/sample](fixtures/sample) through every task. With `CHG_BIN` set, it also drives them
through `chg adapter exec`. CI sets both.
