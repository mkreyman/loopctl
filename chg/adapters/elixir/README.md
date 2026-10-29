# chg Elixir adapter

The `mix chg.*` tasks behind a Mix project's `.chg/adapter.toml` (contract v1,
[docs/adapter-contract.md](../../docs/adapter-contract.md)). They ship as a Mix archive, so a
product repo needs no dependency and no `mix.lock` line:

    scripts/install-elixir-adapter.sh --all-installed   # every asdf Elixir that can run it
    scripts/install-elixir-adapter.sh --repo ~/workspace/home_care_billing   # the Elixir it names
    scripts/install-elixir-adapter.sh      # the Elixir adapters/elixir selects

Archives are per Elixir install, so a repo whose `.tool-versions` moves to a new Elixir has no
`mix chg.*` tasks until the adapter is installed for that one. `scripts/install.sh` runs
`--all-installed` after installing `chg`, so re-running it after `asdf install elixir <v>`
covers the new version. `chg doctor` says whether the tasks are installed for the Elixir a
repo runs, and a gate that finds them missing names the `--repo` command above.

A CI runner that runs as its own user, with its own Elixir and MIX_HOME, cannot use any of
those. `scripts/install-system.sh` puts `chg` at `/usr/local/bin/chg` and the archive at
`/usr/local/share/chg/chg_adapter.ez` for every user, and one built by each asdf-installed
Elixir at `/usr/local/share/chg/elixir/<elixir>-otp-<otp>/chg_adapter.ez`. The job then runs
`mix archive.install /usr/local/share/chg/chg_adapter.ez --force` (or its Elixir's copy) and
`mix local.hex --if-missing --force`. Without Hex, Mix's install prompt would replace the
adapter's JSON output. The job's Elixir and OTP must match the ones that built the archive,
which the `chg_adapter.ez.toolchain` beside it names.

It needs Elixir 1.19.5 or later (`check_cwd: false` exists since 1.19.2), and CI runs its tests
on 1.19.5 and on the version in [.tool-versions](.tool-versions).

A product then adds:

- `.chg/adapter.toml`, copied from [adapter.toml](adapter.toml) and its globs adjusted;
- `elixirc_options: [check_cwd: false]` in `project/0` of `mix.exs`. A workspace hydrated from
  a snapshot sits at a new path, and without this Mix recompiles every module because the
  manifest's cwd differs (design §3.5). Use the project option, not `mix compile --no-check-cwd`:
  `mix test` rejects that flag. `mix chg.snapshot` refuses to run without it.
- no absolute path from compile time that the code or its tests read at run time. Every module
  a change leaves alone keeps the snapshot's build path, which no workspace has. Two forms
  broke HCB's first shadow runs:
  - `__DIR__` or `__ENV__.file` read as a path. Both expand to a fixed string at compile time
    wherever they appear, in a module attribute or a function body alike
    (home_care_billing#2540). In test code, resolve the path from `File.cwd!()`, which `mix test`
    sets to the project root. In application code, use `:code.priv_dir/1` or
    `Application.app_dir/2`, since a release or another start directory has a different cwd.
  - `module_info(:compile)[:source]` or `__info__(:compile)[:source]` read as a file path
    (home_care_billing#2543). Map it to the project instead: the longest suffix of the recorded
    path that exists under `File.cwd!()`.

  A gate that compiles and tests in the same directory never sees either form. A guard test that
  refuses every `__DIR__`, `__ENV__.file` and `[:source]` read outside one helper keeps them from
  coming back (HCB's `project_root_guard_test.exs`).

| Task | Contract command | What it does |
|---|---|---|
| `mix chg.snapshot` | `snapshot` | `deps.get` (recording `mix.lock`'s hash in `deps/.chg_lock`), `chg.compile` in dev and test, the dialyzer PLT (when dialyxir is a dependency), then `mix chg.refs`. Does nothing when HEAD, `mix.lock`, the toolchain and the tree's absolute path match its marker; a tree moved to another path builds again there. |
| `mix chg.refs` | (part of `snapshot`) | Compiles the test files without running them or starting the app, and records each one's module references in `_build/chg/test_refs.etf`. |
| `mix chg.affected --base <sha>` | `affected` | By coverage when `chg` hands it a record (`CHG_COVER`): test files whose recorded run executed a module whose compiled code changed, or that read a changed path `chg` names in `CHG_READ`. Otherwise test files referencing a module changed since `<sha>`, or any module that transitively references one, from Mix's compile manifest, and everything when `CHG_READ` names a path. |
| `mix chg.static --base <sha>` | `static` | `format --check-formatted` and `credo --strict` on the changed files their configs name (`.formatter.exs` inputs, `.credo.exs` default files), `compile --warnings-as-errors`, `dialyzer`. |
| `mix chg.run --tests <list>` | `run` | `mix test` on the listed paths, one result per test. |
| `mix chg.compile [args]` | (every task's compile) | `mix compile args` in a fresh VM that first makes the project's atoms in one sorted order (`ChgAdapter.Atoms`), so two builds of one commit digest alike. |

Every task but `snapshot` first runs `mix deps.get` when `mix.lock` differs from the hash in `deps/.chg_lock`, and records the lock as the fetch left it: a tree hydrated from a snapshot holds the snapshot's deps, and a commit that bumps a dependency would otherwise stop on Mix's "lock mismatch". `static` reports a failed fetch as its one failure.
| `mix chg.shard --of <n> --index <i>` | `shard` | One shard of the whole suite: stable by file name, or balanced by recorded time when `CHG_SHARD_BY` names a record. With `CHG_RECORD` set, it records coverage and timings to that file. |

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

## Coverage selection

The graph selection is sound but dense: on HomeCareBilling's last 200 merged PRs it selected a
median 98% of the suite's time, because nearly every module sits within a few references of a hub
(the Repo, the router, the schemas). Coverage asks what actually ran instead.

Recording (`CHG_RECORD`, on the verifier's whole-suite run, only when the tree is exactly HEAD):
`ChgAdapter.Cover` traces every call into a project module from outside it, in a trace session of
its own, and attributes each to the test modules running at that moment, so work handed to a
GenServer, a Task or the Repo pool still counts. A call made while a test file compiles (a
macro, a module attribute) counts for that file. Calls made at boot, or by a compiling process
whose file is not known, go into a `global` set. Files are recorded the same way: every
`:file`/`:prim_file` call that names a path (reading, opening, stat, listing a directory, which
covers `File` and `Path.wildcard/1`) is a read by the windows open then, and starting a
subprocess (`System.cmd/3`, `:os.cmd/1`) is recorded as `{:spawn, name}`, because its own
reads are not seen. Reads go to the test file whose process made them: every process a test
module's runner starts, transitively, is that module's from the moment it starts, and so is
every process a compiling worker starts. A read by any other process (the Repo pool, a server
the app started) goes to the windows open then, and outside every window into `global_reads`. The record also holds
`ChgAdapter.Digest` of every module, and each test file's time. Tracing costs about 11% of
the suite's time: HomeCareBilling's whole suite on minis at 1191e0fe6 (2026-10-19) ran in 658 s
recorded and 591 s not, back to back, with the load average between 22 and 41.

Selecting (`mix chg.affected`) against the record `chg` hands over in `CHG_COVER`: the nearest
on the base's first-parent line, at most `CHG_COVER_MAX_AGE` (default 100) commits back, with no
`always_all` path changed since it:

- the altered modules are those whose digest differs between the record and the current build
  (new and deleted ones included), plus the readers of an `@external_resource` that changed since
  the base or the record. Everything is compared with the record's green run, not the base, so a
  comment, a line shift or a revert to the record's code alters nothing;
- test data (a file under the test paths that is not a test) changed since the base or the
  record selects the whole suite;
- an altered module in `global`, or a new protocol implementation, selects the whole suite;
- a changed path `chg` names in `CHG_READ` (it matches the manifest's `read_at_runtime`) selects
  the test files that read it, listed a directory above it, or started a subprocess other than
  one the manifest's `not_read_by` names (`CHG_NOT_READ_BY`). One read outside every test file
  (`global_reads`), or such a subprocess started there, selects the whole suite. Such a path is
  not test data, even under the test paths. Without a record it selects the whole suite;
- otherwise the selection is every test file that changed since the base or the record, that the
  record has no coverage of (new), or whose recorded run executed an altered module.

A digest hashes the disassembled code, with what two builds of one commit vary made canonical
(the project root in literals, line numbers, label and lambda numbering, the order of a map
instruction's pairs, LiveView fingerprints), so it is equal across checkouts and machines and
catches a change that reaches a module only at compile time (a macro, a struct default, a module
attribute). Every compile the adapter runs goes through `mix chg.compile`, which starts the
compiling VM with the project's atoms already made in one order (`ChgAdapter.Atoms`): OTP orders
a map's atom keys by when the VM first saw each atom, so code a macro generates from a map
otherwise comes out differently in each build. Records of an older digest form are not compared;
until a new record is published, the graph selection runs. A new module needs no coverage
entry: nothing ran it, so only its own tests and the tests of what now calls it (whose callers
changed and so differ in digest) can observe it. With no usable record (none fetched, too old,
an `always_all` path changed since it, another Elixir or OTP) the graph selection runs, and its
reason says why.

## Environment

`affected`, `static`, `run`, `shard` and `refs` work in `MIX_ENV=test`. Started in another env, a
task runs itself again under `MIX_ENV=test`. The manifest sets `MIX_ENV=test` so `chg` never
pays for the second VM. Mix 1.20 deprecated a task picking its own env, and a product should not
need a `def cli` entry for an archive's tasks.

`mix compile` prunes the code path to the project's own applications, which drops the archive's
ebin. Each task therefore loads all of its modules before it compiles, and `run` calls
`mix test` in the same VM so its formatter stays loaded.

The build path checks commits from every branch against one test database, and a branch's
migration stays there after the next commit, which lacks it, is checked out: `ecto.migrate` cannot
roll back a migration the tree does not have. Before `run` and `shard` start `mix test`, they read
`schema_migrations` for each repo in `:ecto_repos` whose compiled module uses
`Ecto.Adapters.Postgres` (config from `config/*.exs`, `config/runtime.exs` and `:url`). A database
version that no migration file in `priv/**/*migrations/`, the repo's `priv` or its
`migrations_paths` has, and that is newer than the tree's oldest migration, makes the database
ahead. An ahead database is dropped when the `test` alias runs a task before `test` (the product's
setup, which builds it again for this tree), and reported on stderr otherwise. A check that cannot
run is reported and changes nothing. On HCB, a test database carrying one migration from beyond
master failed `follow_ups_test.exs` with 53 `not_null_violation` lines under plain `mix test`, and
passed under `mix chg.run` (minis, 2026-10-19).

## Tests

    mix test test/select_test.exs test/static_test.exs test/runner_test.exs test/snapshot_test.exs \
      test/chg_adapter_test.exs test/digest_test.exs test/shard_test.exs test/head_test.exs \
      test/record_test.exs test/test_db_test.exs test/atoms_test.exs
    CHG_BIN=$PWD/../../target/debug/chg mix test test/integration_test.exs

The integration test builds the archive, installs it into a private `MIX_ARCHIVES`, and drives
[fixtures/sample](fixtures/sample) through every task. With `CHG_BIN` set, it also drives them
through `chg adapter exec`. CI sets both.
