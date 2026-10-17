# Adapter contract, version 1

`chg` talks to a repo's build through `.chg/adapter.toml` (design §3.13). `chg --version` prints the contract version it implements; the manifest declares the version the adapter implements in `adapter.version`, and a mismatch is an error naming both.

## Manifest

| Key | Type | Rule |
|---|---|---|
| `adapter.kind` | string | `elixir` or `pnpm` |
| `adapter.version` | string | must equal the contract version |
| `adapter.artifacts` | non-empty list | repo-relative paths/globs cloned from a snapshot into a workspace |
| `adapter.inputs` | non-empty list | repo-relative globs hashed into a check's input fingerprint |
| `adapter.always_all` | non-empty list | repo-relative globs; touching one selects the whole suite |
| `adapter.isolation_env` | table of strings, optional | exported to every command; may use `{workspace_slot}` |
| `commands.snapshot` | string | may use `{workspace_slot}` |
| `commands.static` | string | must use `{base}` |
| `commands.affected` | string | must use `{base}` |
| `commands.run` | string | must use `{file}` |
| `commands.shard` | string | must use `{n}` and `{i}` |

Paths in `inputs` and `always_all` are globs anchored at the repo root: a `**` segment matches zero or more whole segments, and within a segment `*` matches any run of characters and `?` one character, neither crossing a `/`. So `mix.exs` is only the root file, `config/**` everything under `config/`, and `**/vitest*.config.ts` a Vitest config at any depth. `artifacts` name directories with the same syntax minus `**`, and there a `*` skips names starting with `.`.

Unknown keys, unknown placeholders, a missing or empty command, an empty list, and a path that is absolute or contains `..` are all errors. `chg adapter validate` reports every problem in one pass (exit 0 valid, 1 invalid).

A placeholder is `{` + lowercase letters or underscores + `}`. Anything else in braces is literal shell text: `${HOME}` (a `$` before the brace) and `awk '{print $1}'` pass through, and `{{` writes a literal `{`. Substitution is one pass over the template, so a value is never re-scanned.

Commands run under `sh -c` from the repo root with stdin closed. Substituted values are shell-quoted. `chg` resolves the repo path canonically before use. `{workspace_slot}` is a stable id derived from the workspace path, so two workspaces on one machine never share a test database.

## Output

Each command prints one JSON document as the **last non-empty line of stdout**. Earlier stdout lines (`mix` prints `Compiling …` there) are passed through to stderr. Every schema rejects unknown fields.

| Command | Document |
|---|---|
| `snapshot` | `{"work":"none"\|"incremental"\|"full","ms":N}` |
| `static` | `{"ok":bool,"failures":[{"check":S,"file":S?,"line":N?,"message":S}]}`; `ok` must agree with `failures` |
| `affected` | `{"mode":"subset","reason":S,"tests":[repo-relative path]}` or `{"mode":"all","reason":S}` |
| `run`, `shard` | `{"results":[{"id":S,"status":"pass"\|"fail"\|"skip"\|"error","ms":N}],"junit":S?}`; `run` must report at least one result, a `shard` may be empty |

Shards are 1-based: `chg adapter exec shard --n N --i I` requires `1 <= I <= N`.

## `chg adapter exec <command>` exit codes

- 0: a valid document reporting success.
- 1: a valid document reporting failure (`static.ok` false, or a `fail`/`error` result), from an adapter that exited non-zero.
- 2: the adapter broke the contract: no document, a malformed one, a timeout, or an exit status that disagrees with the document (non-zero with success, zero with failure).

`{file}` (for `run`) is the path of a file listing the tests to run, one repo-relative `path` or `path:line` per line: the list `affected` returned.

A result `id` starts with the test's repo-relative file. What follows is nothing (the whole file, e.g. one that failed to load), `:<line>`, or ` > <name>`. `chg culprit` turns an id back into a `run` entry by dropping any ` > <name>`, and matches the results it gets by id.

Before running `affected`, `chg` compares the changed paths against `always_all` and, on a hit, prints `{"mode":"all","reason":"<path> matches always_all `<glob>`"}` without calling the adapter. The changed paths are those differing between `--base` and the working tree, tracked or untracked, with renames split into the deleted and the added path (`git diff --no-renames --name-only <base>` plus `git ls-files --others --exclude-standard`). An adapter selects within the same set and does not apply `always_all` itself. A `--base` that is not a commit fails closed.

`affected` never exits 2. Any of those failures **fails closed**: it prints `{"mode":"all","reason":"failed closed: …"}` and the reason on stderr, and exits 0, so the caller runs the whole suite.

Wall-clock caps (override with `--timeout-secs`): snapshot 30 min, static 15, affected 5, run 15, shard 20. Stdout is relayed to stderr as it arrives (minus the newest line, held back as the candidate document), so a hung command still shows how far it got. When the command exits or times out, `chg` kills its whole process group, so no helper it started outlives it.
