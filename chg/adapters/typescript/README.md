# chg TypeScript adapter

The adapter behind a pnpm workspace's `.chg/adapter.toml` (contract v1,
[docs/adapter-contract.md](../../docs/adapter-contract.md)), for TypeScript packages tested with
Vitest and Playwright. It is one Node script with no npm dependencies. It drives the product's
own pnpm, `vitest`, `playwright`, `eslint` and `tsc`, so their versions are the product's:

    scripts/install-typescript-adapter.sh      # once per machine: ~/.local/share/chg/typescript

A product then adds `.chg/adapter.toml`, copied from [adapter.toml](adapter.toml) (fleet-holding
shaped) with its globs, `--generate`, `--tsconfig` and `--check` lines adjusted.

| Command | What it does |
|---|---|
| `snapshot [--build <filter>] [--generate <sh>]... [--browsers <names>] [--tsconfig <dir>]...` | `pnpm install --frozen-lockfile` with the product's own pnpm settings, `pnpm --filter <filter> run --if-present build` (default `./packages/*`, `none` skips), the `--generate` commands, `playwright install <names>` when given, then a warm incremental typecheck. Does nothing when HEAD, the lockfile, node, pnpm and the options match its marker in `node_modules/.chg/`. |
| `affected --base <sha> [--ignore <glob>]... [--e2e-grep <re>] [--apps <glob>]...` | Test files reached from the changed modules by Vitest's import graph, Playwright specs reached by Playwright's, and, when an `--apps` package is touched, the specs matching `--e2e-grep`. |
| `static --base <sha> [--generate <sh>]... [--tsconfig <dir>]... [--check <name>=<sh>]...` | eslint on the changed code files, `tsc --noEmit` on every package with a `tsconfig.json` plus each `--tsconfig`, and each `--check` (run under `sh -c` with `CHG_BASE` and `CHG_HEAD` set), concurrently. |
| `run --tests <list>` | Vitest for the listed test files, Playwright for those under `--e2e-dir` (default `e2e`); one result per test, `file > full name`. |
| `shard --of <n> --index <i> [--e2e]` | Vitest's `--shard=i/n`, plus Playwright's when `--e2e` is given. |

## How `affected` selects

Every changed path, against the base and including untracked files, lands in one class:

- Ignored: matches an `--ignore` glob. It selects nothing.
- Code: a `.ts`/`.tsx`/`.js`/`.mjs`/… source that still exists, in a package or under
  `--e2e-dir`. It goes to `vitest list --changed <sha>` and
  `playwright test --list --only-changed=<sha>`. Both follow the import graph, so a module's
  tests and its importers' tests in other packages are found.
- Blind: a deleted source, or a non-code file (SQL, fixtures, text read at runtime) inside a
  package. The graph cannot see these: Vitest ignores deleted sources, and nothing imports a
  `.txt`. The owning package (the deepest one containing the path) and every workspace package
  depending on it, transitively as `pnpm --filter ...pkg` would, contribute all their test files.
- Outside: any other path, code included. It selects everything: repo scripts outside the
  packages are often run as a subprocess by their tests, which no import graph sees.

`always_all` is applied by `chg` before the adapter runs. Any error (an unknown base, a runner
that will not list, an unknown option) gives `{"mode":"all"}` with the reason, never an empty
subset. The other commands answer an error with their failure document: `static` a failure
with check `adapter`, `run` and `shard` an `adapter` error result. A runner that exits
non-zero while every test it reported passed (an unhandled error after a test) adds an error
result named after the runner.

## Typecheck cost

A workspace without TypeScript project references gets no help from `tsc -b`. Each package is
therefore checked with `--incremental` and a build-info file under `node_modules/.cache/chg/tsc/`,
which the snapshot warms. On fleet-holding, `apps/api` takes 9.75 s cold and 1.59 s warm.
Generated sources that are gitignored (`apps/web/src/routeTree.gen.ts`) must be produced by a
`--generate` step, or `tsc` fails on the missing module.

## Tests

    node --test test/unit.test.mjs test/integration.test.mjs
    CHG_BIN=../../target/debug/chg node --test test/integration.test.mjs

They need node from [.tool-versions](.tool-versions) and pnpm 12. The integration test copies
[fixtures/sample](fixtures/sample) into a git repo under the temp dir, installs it and drives
every command. With `CHG_BIN` set, it also drives `chg adapter exec`, where `always_all`
applies. CI sets it.
