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

`affected` never exits 2. Any of those failures **fails closed**: it prints `{"mode":"all","reason":"failed closed: …"}` and the reason on stderr, and exits 0, so the caller runs the whole suite.

Wall-clock caps (override with `--timeout-secs`): snapshot 30 min, static 15, affected 5, run 15, shard 20. Stdout is relayed to stderr as it arrives (minus the newest line, held back as the candidate document), so a hung command still shows how far it got. When the command exits or times out, `chg` kills its whole process group, so no helper it started outlives it.
