defmodule Loopctl.HeavyRead do
  @moduledoc """
  The ONLY sanctioned entry point for heavy, BYPASSRLS reads (US-27.11).

  `Loopctl.HeavyReadRepo` has BYPASSRLS, so RLS does not scope its queries — the
  `tenant_id` predicate is the only thing standing between tenant A and tenant
  B's rows. This module makes mis-scoping that predicate fail fast (AC-27.11.4).

  ## What the guard proves

  A query is accepted only if EVERY base-table source it reads from — the `from`
  table AND every joined table — is constrained by a CONJUNCTIVE
  `x.tenant_id == ^tenant_id` equality on THAT source's binding, bound to the
  `tenant_id` argument passed in; `from`/`join` SUBQUERY sources are required to
  be scoped the same way, recursively. Concretely this rejects:

    * an unscoped `from` (the primary table read without a tenant filter), even
      if a *joined* table is scoped;
    * a joined table with no tenant filter on it (its rows could cross tenants);
    * a tenant predicate that is OR-ed with a broadening condition
      (`tenant_id == ^t or status == :published`) — the tenant predicate must be
      AND-combined, not re-admitting other tenants;
    * `tenant_id != ^x`, `is_nil(tenant_id)`, or an equality to a DIFFERENT
      tenant than the caller.

  ## Limits (not proven)

  This is a strong necessary gate, not a proof of full query correctness. The
  tenant predicate MUST be an Ecto field comparison `x.tenant_id == ^id` (a raw
  `fragment("tenant_id = ?", ^id)` is rejected — scope through the schema field).
  A source that is neither a schema table nor a from/join subquery (a raw
  `fragment` from, a CTE reference) is not structurally validated, and NEITHER is a
  subquery in a WHERE/HAVING expression (`where: x.id in subquery(q)`): only `from`
  and joins are walked, so reason about what such a subquery reads at the call site.

  A companion build guard (`test/loopctl/heavy_read_guard_test.exs`) fails if any
  `lib/` module other than this one reaches `Loopctl.HeavyReadRepo` directly, so
  the only path to the heavy-read pool is through this tenant-checked wrapper.

  ## Repo resolution (config-based DI)

  The backing repo is resolved via `Application.get_env(:loopctl, :heavy_read_repo,
  Loopctl.HeavyReadRepo)`. Production/dev use the dedicated `HeavyReadRepo` pool.
  The test env points it at `Loopctl.AdminRepo` (config/test.exs) so heavy reads
  share the sandbox connection that fixtures insert through. The guard and tenant
  isolation are repo-agnostic and fully exercised regardless of which repo backs
  it; the per-read `SET LOCAL statement_timeout` mechanism is exercised directly on the
  dedicated pool by `heavy_read_repo_test.exs` / `heavy_read_pool_isolation_test.exs` (incl.
  a real Ecto query canceled by the timeout). (US-27.13: the timeout is applied per-read via
  SET LOCAL, NOT a startup `:parameters` — pgbouncer rejects the latter with 08P01.) True
  OS-level pool starvation is not
  reproducible under Sandbox, so TC-27.11.1's concurrency guarantee is structural
  (separate pools + bounded hold) and is re-verified under load per
  docs/runbooks/knowledge-scale.md.
  """

  require Logger

  alias Loopctl.ExitTag
  alias Loopctl.HeavyRead.TenantGate
  alias Loopctl.LocalGuc

  @doc "Resolved heavy-read repo (DI). `HeavyReadRepo` in prod/dev, `AdminRepo` in test."
  @spec repo() :: module()
  def repo, do: Application.get_env(:loopctl, :heavy_read_repo, Loopctl.HeavyReadRepo)

  # US-38.1: endpoints whose reads are CONSISTENCY-COUPLED to a primary read and therefore
  # MUST run on the primary pool even when a read replica is configured
  # (`REPLICA_DATABASE_URL`). `:sth_incremental` reads `audit_chain` entry hashes that are
  # folded together with the chain HEAD (`latest_entry/1`, AdminRepo) and the STH CHECKPOINT
  # (`load_valid_checkpoint/2`, AdminRepo) read from the PRIMARY in the SAME
  # `Loopctl.AuditChain.sign_and_store_tree_head/1` operation. An async replica lagging by k
  # entries would return only `[0..N-k]` for a tail bounded at the primary head N, so the
  # signer would fold an INCOMPLETE tail and emit a WRONG signed Merkle root LABELED at
  # position N — violating the audit chain's "never emit a wrong signed root" invariant and
  # poisoning the next incremental checkpoint. Pinning the pool keeps ALL of HeavyRead's
  # protections (per-read `SET LOCAL statement_timeout`, tenant guard, TenantGate); only the
  # backing pool changes. The pin is GATED on a distinct replica actually being configured
  # (`Loopctl.DbCapacity.replica_configured?/0`): with NO replica it is INERT — `repo_for/1`
  # keeps EVERY endpoint (pinned ones included) on the heavy-read pool (`repo/0`), byte-identical
  # to pre-US-38.1 (STH reads never move onto AdminRepo's tight write pool just because
  # `primary_repo/0` defaults to AdminRepo != HeavyReadRepo). Only once `REPLICA_DATABASE_URL`
  # routes other heavy reads to a lagging replica do the pinned endpoints divert to
  # `primary_repo/0` to stay on the same snapshot as the head/checkpoint reads.
  @primary_pinned_endpoints ~w(sth_incremental)a

  @doc """
  Heavy-read endpoints PINNED to the primary pool (never the read replica) — US-38.1.

  A read tagged with one of these endpoints is consistency-coupled to a primary read and
  runs on `primary_repo/0` even when `REPLICA_DATABASE_URL` is configured. See the
  `@primary_pinned_endpoints` note for why `:sth_incremental` cannot tolerate replica lag.
  """
  @spec primary_pinned_endpoints() :: [atom()]
  def primary_pinned_endpoints, do: @primary_pinned_endpoints

  @doc """
  The PRIMARY BYPASSRLS repo — the pool backing consistency-coupled heavy reads
  (`primary_pinned_endpoints/0`) once a distinct read replica is configured.

  Resolved via config DI (defaults to `Loopctl.AdminRepo`, which is the primary BYPASSRLS
  pool in prod and the sandbox repo in test). It is only CONSULTED by `repo_for/1` when a
  distinct replica is configured (`Loopctl.DbCapacity.replica_configured?/0`); with NO replica
  `repo_for/1` never routes here, so routing stays byte-identical to `repo/0` even though
  `primary_repo/0` (AdminRepo) is NOT the same module as `repo/0` (HeavyReadRepo) in prod.
  """
  @spec primary_repo() :: module()
  def primary_repo, do: Application.get_env(:loopctl, :heavy_read_primary_repo, Loopctl.AdminRepo)

  @doc false
  # Which repo backs a read for `endpoint`: the PRIMARY pool for a consistency-coupled
  # endpoint (`primary_pinned_endpoints/0`) ONLY when a distinct replica is configured, else the
  # resolved heavy-read pool (`repo/0`, which targets the replica when `REPLICA_DATABASE_URL`
  # is set). Delegates the pure decision to `route_repo/4` (the DI seam). Public (arity-1 atom)
  # so the pinning invariant is unit-testable.
  @spec repo_for(atom() | nil) :: module()
  def repo_for(endpoint) do
    route_repo(endpoint, Loopctl.DbCapacity.replica_configured?(), repo(), primary_repo())
  end

  @doc false
  # Pure routing decision (DI seam). Under `mix test` `repo() == primary_repo() == AdminRepo`,
  # so a `repo_for/1` equality assertion is tautological and cannot catch the prod
  # AdminRepo/HeavyReadRepo divergence; this arity-4 form takes the resolved repos as arguments
  # so the pin is testable with DISTINCT sentinel modules WITHOUT `Application.put_env`.
  #
  # A consistency-coupled endpoint is pinned to the PRIMARY pool ONLY when a distinct read
  # replica is actually configured. With NO replica, every endpoint (pinned ones included) stays
  # on the heavy-read pool (`repo`), keeping routing byte-identical to pre-US-38.1 — no STH read
  # is diverted onto AdminRepo's tight write pool.
  @spec route_repo(atom() | nil, boolean(), module(), module()) :: module()
  def route_repo(endpoint, replica_configured?, repo, primary_repo) do
    if replica_configured? and endpoint in @primary_pinned_endpoints do
      primary_repo
    else
      repo
    end
  end

  @doc false
  # US-38.1 boot readiness probe (AC-38.1.2): a trivial round-trip on the resolved heavy-read
  # pool (the REPLICA when `REPLICA_DATABASE_URL` is configured). Lives here — the sole
  # sanctioned toucher of the heavy-read pool — so `Loopctl.ReplicaReadiness` can fail loud at
  # boot on an unreachable replica WITHOUT itself referencing `Loopctl.HeavyReadRepo` (which
  # the build guard forbids). Returns `:ok` or `{:error, reason}`; never raises.
  @spec probe() :: :ok | {:error, term()}
  def probe do
    case repo().query("SELECT 1", [], timeout: 5_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc false
  # US-38.1: the REPLICA pool's live `max_connections`, read through the sole sanctioned
  # toucher of the heavy-read pool so `Loopctl.DbCapacity` can budget the replica-side pool at
  # boot WITHOUT referencing `Loopctl.HeavyReadRepo` directly (the build guard forbids it —
  # same reason `probe/0` lives here). Returns `{:ok, n}` or `{:error, reason}`; never raises.
  @spec replica_max_connections() :: {:ok, pos_integer()} | {:error, term()}
  def replica_max_connections do
    case repo().query("SHOW max_connections", [], timeout: 5_000) do
      {:ok, %{rows: [[raw]]}} -> {:ok, String.to_integer(raw)}
      {:ok, other} -> {:error, {:unexpected_result, other}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Per-read options for a heavy endpoint (US-27.4): the 15s CLIENT timeout backstop plus
  the SERVER-SIDE `:statement_timeout` — the per-endpoint override (config
  `:heavy_read_statement_timeout_overrides`, e.g. `%{suggested_links: 5_000}`) if set,
  ELSE the pool-wide default (`:heavy_read_statement_timeout_ms`, 10s). It is ALWAYS
  present, so every heavy read is wrapped in a `SET LOCAL statement_timeout` transaction.

  This replaced a connection-startup `parameters: [statement_timeout: ...]` lever
  (US-27.11) that Fly MPG's pgbouncer rejected with `08P01 unsupported startup
  parameter`, crash-looping the whole HeavyReadRepo pool and 503ing every heavy endpoint
  (US-27.13). `SET LOCAL` inside a transaction is the pgbouncer-safe way to set a
  server-side statement_timeout. Also passes the endpoint key via `telemetry_options` so
  slow-query logs can trace which endpoint triggered the query.

  For a pgvector-ANN endpoint (`ann_endpoints/0`) it ALSO carries `:hnsw_ef_search`
  (US-38.4) — the per-query recall breadth applied via `SET LOCAL hnsw.ef_search` inside
  the same heavy-read transaction — but ONLY when the live `SystemConfig` value differs
  from pgvector's default (at the default no key is attached, so a role-level `ALTER ROLE`
  override is not shadowed; see `hnsw_ef_search/0`). `all/3`/`one/3`/`all_memory/4` pop it
  (like `:statement_timeout`) before handing the remaining opts to the repo.

  This is the SINGLE source of truth for heavy-read opts — every consumer
  (`Loopctl.Knowledge`, `Loopctl.Audit`) builds opts via this function so the
  `[timeout, telemetry_options, statement_timeout, hnsw_ef_search]` shape can't drift
  between callers.
  Known endpoints are enumerated in `known_endpoints/0`: `:suggested_links`,
  `:semantic_search`, `:distant_pairs`, `:distant_pairs_bridge` (the slower
  `bridge_path=true` branch — its own key so its statement_timeout/slow-query
  telemetry are distinct), `:novelty`, `:enumeration`, `:change_feed`,
  `:vector_search` (the shared kNN helper path), `:memory_recall` (the US-28.2
  agent-memory HNSW recall via `all_memory/4`), `:ingestion_jobs` (the US-34.6
  `GET /knowledge/ingestion-jobs` COUNT + list over the Oban-owned `oban_jobs` table,
  bounded by a partial expression index), `:sth_incremental` (the US-35.1 bounded
  "entries above the STH checkpoint" tail read over `audit_chain`, folded into the
  persisted Merkle peaks — PRIMARY-PINNED per `primary_pinned_endpoints/0`: it is
  consistency-coupled to the chain head/checkpoint read from the primary in the same STH
  sign, so it never runs on a lagging read replica), `:export` (the US-27.16 long
  streamed-export scans), and
  `:llm_usage` (the customer-facing LLM-usage aggregate over `llm_usage_events`, a
  bounded indexed COUNT/GROUP BY — classified LIGHT by the gate), and `:graph_lane` (the
  #470 opt-in graph-neighbor lane of `search_combined/3`: a bounded, index-backed
  `ArticleLink` seed-set read plus a bounded neighbor-article fetch — classified HEAVY by
  the gate since it fans a preload across up to `@graph_lane_link_limit` link rows).
  """
  # US-38.4: the pgvector-ANN (kNN) endpoints whose reads run an index-ordered
  # `ORDER BY (embedding cosine-distance $const) LIMIT k` scan against the HNSW index and are
  # therefore governed by `hnsw.ef_search`. ONLY these get a per-read `SET LOCAL hnsw.ef_search`
  # (see `maybe_put_ef_search/2`), and only when the configured value differs from the
  # pgvector default. The non-ANN heavy reads
  # (enumeration/change_feed/ingestion_jobs/sth_incremental/export/llm_usage) never touch
  # the HNSW index, so setting the GUC on them would be dead work.
  #
  # `distant_pairs`/`distant_pairs_bridge` are DELIBERATELY EXCLUDED even though they read
  # `articles.embedding`: they are column-to-column (embedding-to-embedding) cosine-distance
  # self-joins with NO `$const` target vector, so pgvector's HNSW index cannot apply to them
  # by nature — the codebase's own `Loopctl.Knowledge.CosineLintExceptions` registers
  # `do_distant_pairs/7` with exactly that rationale ("no $const target, HNSW N/A").
  # `hnsw.ef_search` only affects index-ordered `ORDER BY <distance> LIMIT k` kNN scans, so a
  # `SET LOCAL hnsw.ef_search` on those self-joins would be a no-op round-trip with zero
  # recall/latency effect. A subset of `@known_endpoints` (asserted by the ann-endpoints test).
  @ann_endpoints ~w(
    suggested_links
    semantic_search
    novelty
    vector_search
    memory_recall
  )a

  # pgvector's default `hnsw.ef_search` (the per-query search breadth / recall ceiling).
  @default_hnsw_ef_search 40

  @spec opts(atom()) :: keyword()
  def opts(endpoint) when is_atom(endpoint) do
    base = [timeout: 15_000, telemetry_options: [endpoint: endpoint]]

    base
    |> Keyword.put(:statement_timeout, statement_timeout_for(endpoint))
    |> maybe_put_ef_search(endpoint)
    |> maybe_put_iterative_scan(endpoint)
  end

  # US-38.4: attach the per-QUERY `hnsw.ef_search` recall breadth ONLY to the
  # pgvector-ANN endpoints (`ann_endpoints/0`), and ONLY when the live SystemConfig value
  # DIFFERS from pgvector's built-in default. A `SET LOCAL hnsw.ef_search = N` then
  # piggybacks on the SAME short `SET LOCAL statement_timeout` transaction every heavy read
  # already runs in (US-27.13), so it adds NO new pool-starvation risk (the historical
  # objection that per-request `SET LOCAL` "needs a transaction" is stale — the transaction
  # is already there). Non-ANN endpoints (audit/enumeration/export) get no ef_search key, so
  # an unused GUC is never set on their connections.
  #
  # Emitting SET LOCAL ONLY for a NON-default value is deliberate (US-38.4 review fix): a
  # `SET LOCAL` overrides any role/session default for the duration of its transaction, so
  # unconditionally setting the pgvector default would silently SHADOW a role-level
  # `ALTER ROLE <role> SET hnsw.ef_search = N` on every ANN read. Skipping the emission at
  # the default keeps `SystemConfig` the fleet-wide lever (a non-default value wins per-read)
  # WITHOUT clobbering a role-level override when `SystemConfig` is left at the default — and
  # it means the common (default) path issues no ANN GUC round-trip at all.
  defp maybe_put_ef_search(opts, endpoint) do
    if endpoint in @ann_endpoints do
      case ef_search_override() do
        nil -> opts
        ef -> Keyword.put(opts, :hnsw_ef_search, ef)
      end
    else
      opts
    end
  end

  # #488: attach the per-QUERY `hnsw.iterative_scan` mode to the pgvector-ANN endpoints
  # ONLY, and ONLY when an operator has turned it ON (SystemConfig `"hnsw_iterative_scan"`
  # != "off"). It rides the SAME `SET LOCAL statement_timeout` transaction as ef_search,
  # so it adds no new pool-starvation risk. It exists because the ANN filters `tenant_id`
  # as a POST-index residual on a cross-tenant partial HNSW index: without iterative scan,
  # a tenant whose near rows fall outside the global top-`ef_search` is silently
  # under-returned. Default OFF so this is a NO-OP (and pgvector < 0.8, which lacks the GUC,
  # never sees the `SET LOCAL`) until an operator enables it after verifying the deployed
  # pgvector is >= 0.8 — a single `SystemConfig` UPDATE, no redeploy.
  defp maybe_put_iterative_scan(opts, endpoint) do
    if endpoint in @ann_endpoints do
      case iterative_scan_override() do
        nil -> opts
        mode -> Keyword.put(opts, :hnsw_iterative_scan, mode)
      end
    else
      opts
    end
  end

  # The per-read `hnsw.ef_search` value to APPLY via `SET LOCAL`, or `nil` to leave the
  # session/role default untouched. `nil` exactly when the configured (clamped) value equals
  # pgvector's built-in default — so a role-level `ALTER ROLE ... SET hnsw.ef_search` override
  # is honored rather than shadowed by an identical-to-default per-read `SET LOCAL`.
  @spec ef_search_override() :: pos_integer() | nil
  defp ef_search_override do
    case hnsw_ef_search() do
      @default_hnsw_ef_search -> nil
      ef -> ef
    end
  end

  # Every endpoint atom a caller passes to `opts/1` / stamps into `telemetry_options`.
  # `opts/1` itself accepts ANY atom (the timeout defaults are endpoint-agnostic), but
  # `Loopctl.HeavyRead.TenantGate.weight_for/1` partitions these into heavy vs light
  # cost weights — so this list is the SOURCE OF TRUTH the gate's drift guard
  # (`tenant_gate_test.exs`) checks its `@heavy_endpoints` against: a new endpoint
  # added here without a deliberate heavy/light weight decision fails that test rather
  # than silently defaulting to light weight and under-charging a heavy read.
  @known_endpoints ~w(
    suggested_links
    semantic_search
    distant_pairs
    distant_pairs_bridge
    novelty
    enumeration
    change_feed
    vector_search
    memory_recall
    ingestion_jobs
    sth_incremental
    export
    llm_usage
    graph_lane
    heat_index
  )a

  @doc """
  The known heavy-read endpoint atoms (documented in `opts/1`).

  The canonical set `Loopctl.HeavyRead.TenantGate` assigns cost weights to; the gate's
  drift guard test partitions exactly this set into heavy vs light so a newly-added
  endpoint can't silently fall through to light weight.
  """
  @spec known_endpoints() :: [atom()]
  def known_endpoints, do: @known_endpoints

  @doc """
  The pgvector-ANN endpoints that carry a per-read `hnsw.ef_search` (subset of
  `known_endpoints/0`).
  """
  @spec ann_endpoints() :: [atom()]
  def ann_endpoints, do: @ann_endpoints

  @doc """
  The configured per-query `hnsw.ef_search` recall breadth (US-38.4), clamped to
  pgvector's accepted `[1, 1000]` range.

  Read from the live-tunable `SystemConfig` key `"hnsw_ef_search"` (a missing row →
  the pgvector default #{@default_hnsw_ef_search}), so an operator can raise recall
  fleet-wide with a single `UPDATE` — no redeploy. Clamped so a bad config value can
  never make the `SET LOCAL hnsw.ef_search` raise and roll back the read; a value outside
  the range is pulled to the nearest bound.

  NB: this returns the configured value even when it EQUALS the default. Whether a per-read
  `SET LOCAL` is actually issued is decided by `maybe_put_ef_search/2`: at the default NO
  `SET LOCAL` fires (so a role-level `ALTER ROLE <role> SET hnsw.ef_search` is honored,
  never shadowed); a NON-default value is applied per-read via `SET LOCAL` inside the
  heavy-read transaction (`run_timed_transaction/5`), taking precedence over any role/session
  default for that ANN read.
  """
  @spec hnsw_ef_search() :: pos_integer()
  def hnsw_ef_search do
    Loopctl.SystemConfig.get_int("hnsw_ef_search", @default_hnsw_ef_search)
    |> max(1)
    |> min(1000)
  end

  # `SystemConfig` is integer-only (get_int/put), so the mode is an INT CODE — this keeps
  # the same single-UPDATE operator lever ef_search uses. The mode string is looked up from
  # a fixed table, so the value interpolated into `SET LOCAL hnsw.iterative_scan = <mode>`
  # is ALWAYS one of the three literals below, never operator/attacker text.
  # The SHIPPED fallback: pgvector's own default, OFF.
  #
  # A review of this branch proposed flipping it to 1 so the shipped default matches what
  # prod runs and what `config/test.exs` pins — the argument being that the ON state lives
  # only in an operator-set `SystemConfig` row, so a fresh self-hosted install silently runs
  # a configuration the suite does not assert. That argument has real merit, and the change
  # is guarded (`iterative_scan_supported?/0` makes it a NO-OP below pgvector 0.8, and
  # `hnsw_max_scan_tuples/0` bounds the walk).
  #
  # It is NOT taken here, because flipping it changes ANN query planning for every
  # deployment that has not set the row — a fleet-wide performance/recall trade that is the
  # operator's call, not a side effect of a branch fixing six unrelated findings. The
  # premise gap it targets is closed the honest way instead: `hnsw_iterative_scan/0`'s @doc
  # below states all three values and records how the prod one is verified and when it was
  # last checked (`docs/hnsw-tuning-evaluation.md` carries the operator-facing copy). Raise
  # it as its own change if the default should move.
  @default_hnsw_iterative_scan 0
  @hnsw_iterative_scan_modes %{1 => "relaxed_order", 2 => "strict_order"}
  @default_hnsw_max_scan_tuples 20_000

  @doc """
  The configured `hnsw.iterative_scan` mode for ANN reads (#488): `"off"`, `"relaxed_order"`,
  or `"strict_order"`.

  Read from the live-tunable `SystemConfig` key `"hnsw_iterative_scan"` as an INT CODE
  (0 = off — **the shipped default** — 1 = relaxed_order, 2 = strict_order, unknown = the
  shipped default), so an operator turns iterative scan off or up fleet-wide with a single
  `UPDATE` — no redeploy.

  ## Three values, deliberately not all the same

  | Where | Value | Why |
  |---|---|---|
  | shipped `@default_hnsw_iterative_scan` | `0` (off) | a fresh install makes no latency/recall trade it did not ask for |
  | prod `SystemConfig` row | `1` (relaxed_order) | operator-set in #488; verified against the live app 2026-08-01 |
  | `config/test.exs` pin | `1` | the suite asserts recall against WHAT PROD RUNS, not against the shipped default |

  The test pin therefore does NOT match the shipped attribute, and must not be "corrected"
  to: leaving test unpinned is what made CI assert exact recall against a configuration
  nobody runs, which is the long-running side-table `left: []` flake
  (`config/test.exs`, and see `test/loopctl/embeddings_side_table_reads_test.exs`).

  Whether the SHIPPED default should move to `1` is an open operator decision — a fleet-wide
  latency-for-recall trade — and is deliberately not settled here. What is settled is that
  this doc states all three values, because an earlier revision claimed `1` was the shipped
  default and that the test pin matched it; both were false, and a reader reasoning from
  either would have mis-predicted what a fresh install does.

  `SystemConfig` is the operator lever and the only RUNTIME source. When no operator has set
  that row, the fallback code comes from the config key `:hnsw_iterative_scan_default`
  (`default_iterative_scan_code/0`), which ONLY `config/test.exs` sets. Every NON-test config
  is barred from setting that key by
  `test/loopctl/config_embedding_read_path_test.exs`; an `Application` pin in prod would
  shadow the operator lever. Tests that need a specific mode prime the `SystemConfig` cache
  explicitly in an `async: false` module (see
  `test/loopctl/heavy_read_hnsw_ef_search_test.exs`).

  Operator docs: `docs/hnsw-tuning-evaluation.md` and `docs/runbooks/knowledge-scale.md`.
  """
  @spec hnsw_iterative_scan() :: String.t()
  def hnsw_iterative_scan do
    Map.get(@hnsw_iterative_scan_modes, iterative_scan_code(), "off")
  end

  defp iterative_scan_code do
    Loopctl.SystemConfig.get_int("hnsw_iterative_scan", default_iterative_scan_code())
  end

  # `SystemConfig` stays the single operator lever; this is only the FALLBACK applied when no
  # operator has set that row. It is config-injected (rather than read straight off the module
  # attribute) so an environment can start from a different baseline without any test mutating
  # VM-global state. Only `config/test.exs` sets it, and DELIBERATELY NOT to the shipped
  # attribute's value: the suite asserts recall against what PROD runs (the operator-set
  # `SystemConfig` row, 1) rather than against the shipped default (0). See the
  # `hnsw_iterative_scan/0` @doc's table — an earlier revision of this comment claimed the two
  # matched, which would send whoever next reads it to "fix" the pin and reopen the
  # side-table flake.
  # Every NON-test config is barred from setting `:hnsw_iterative_scan_default` — the key
  # read RIGHT BELOW — by `test/loopctl/config_embedding_read_path_test.exs`, which also
  # asserts `config/test.exs` still sets it. That is the case that matters: an Application
  # pin in prod would shadow the operator lever. (Name the key exactly: the guard policed
  # only the pre-rename `:hnsw_iterative_scan` for a while, so this comment claimed a
  # control that did not cover the key the function actually reads.)
  defp default_iterative_scan_code do
    case Application.get_env(:loopctl, :hnsw_iterative_scan_default, @default_hnsw_iterative_scan) do
      code when is_integer(code) -> code
      _ -> @default_hnsw_iterative_scan
    end
  end

  @doc """
  The `hnsw.max_scan_tuples` ceiling applied alongside `hnsw.iterative_scan` (#488) —
  bounds how far iterative scan may walk before giving up, so a pathological query cannot
  scan the whole relation. Live-tunable via `SystemConfig` `"hnsw_max_scan_tuples"`
  (pgvector's default #{@default_hnsw_max_scan_tuples}), clamped to a sane `[1, 1_000_000]`
  so a bad value can never make the `SET LOCAL` raise and roll back the read.
  """
  @spec hnsw_max_scan_tuples() :: pos_integer()
  def hnsw_max_scan_tuples do
    Loopctl.SystemConfig.get_int("hnsw_max_scan_tuples", @default_hnsw_max_scan_tuples)
    |> max(1)
    |> min(1_000_000)
  end

  # The per-read `hnsw.iterative_scan` mode to APPLY via `SET LOCAL`, or `nil` when OFF
  # (the default) — so the common path issues NO iterative-scan GUC round-trip and pgvector
  # versions without the GUC are never touched. When an operator HAS enabled it, the
  # capability probe (`iterative_scan_supported?/0`) is the second gate: on a pgvector < 0.8
  # backend (no such GUC) it returns `nil` too, so enabling the config there is a NO-OP
  # rather than a fleet-wide ANN outage. The `"off"` clause short-circuits BEFORE the probe,
  # so the default path never pays for it.
  @spec iterative_scan_override() :: String.t() | nil
  defp iterative_scan_override do
    case hnsw_iterative_scan() do
      "off" -> nil
      mode -> if iterative_scan_supported?(), do: mode, else: nil
    end
  end

  @iterative_scan_min_version {0, 8, 0}

  # Conclusive verdicts are long-lived but NOT permanent (the backend can change under us);
  # inconclusive verdicts are negative-cached briefly so a degraded backend costs one probe
  # + one log line per window, not one per ANN read.
  @iterative_scan_cache_ttl_ms 600_000
  @iterative_scan_negative_ttl_ms 60_000

  # A fail-closed GUESS (inconclusive probe, no conclusive verdict to reuse) starts far
  # SHORTER and BACKS OFF from there. At boot the very first ANN read's probe can hit
  # 53300/57014 on a saturated pool, and negative-caching that for a full minute pins
  # iterative scan OFF fleet-wide on the node, silently re-arming the cross-tenant
  # post-ANN-filter under-return (`left: []`) this feature exists to close. But a FIXED one
  # second is the opposite failure: a SUSTAINED saturation then costs a probe checkout every
  # ~1.5s, landing ahead of `TenantGate`'s shed — the storm the negative cache exists to
  # bound. Doubling per CONSECUTIVE guess buys both: a boot blip self-heals in a second, a
  # real incident converges on the full negative window.
  @iterative_scan_unknown_ttl_ms 1_000

  # How long a CONCLUSIVE verdict stays usable as the inconclusive fallback. Longer than the
  # live cache (a fallback that expired with it could never be reached) but NOT forever: the
  # backend CAN change under us (replica failover, extension downgrade), and replaying a stale
  # `true` onto a pgvector < 0.8 backend emits a GUC it rejects, which raises inside
  # `run_timed_transaction/5` and 500s every ANN read. This bounds that window; past it an
  # unaskable backend falls closed again.
  @iterative_scan_last_conclusive_ttl_ms 3_600_000

  # See `probe_iterative_scan_support/0`: this bounds the pre-gate checkout, not just the
  # query, so it is deliberately far below the sibling probes' budget. It is the TOTAL
  # budget for the probe, and `savepoint_first_probe/0` takes TWO checkouts on prod's idle
  # shape (the refused savepoint, then the plain retry), so each ATTEMPT gets half and the
  # pair still fits the bound this attribute — and the operator docs — state.
  @probe_timeout_ms 500
  @probe_attempt_timeout_ms div(@probe_timeout_ms, 2)

  @doc """
  Whether the connected pgvector supports `hnsw.iterative_scan` (pgvector >= 0.8.0).

  Probed from `pg_extension` on the SAME repo the ANN read runs on (`repo/0`) under a
  #{@probe_timeout_ms}ms TOTAL budget (`@probe_timeout_ms`, which bounds the pre-gate
  CHECKOUT, not just the query, and is split across the probe's two attempts) and cached in
  `:persistent_term` WITH A TTL. The probe runs only when an operator has actually enabled
  iterative scan (`iterative_scan_override/0` short-circuits at OFF), so it costs one extra
  round-trip per TTL window on the enabled path and nothing at all on the default path.

  A CONCLUSIVE probe that says no — missing row, unparseable version, or a version below the
  floor — is `false`, so no `hnsw.iterative_scan` GUC is emitted against a backend that would
  reject it and abort the heavy-read transaction; that is the "safe on pgvector < 0.8"
  guarantee. An INCONCLUSIVE probe (a DBConnection/Postgrex EXIT or error — "I could not
  ask", never "the extension is missing") reuses the last CONCLUSIVE verdict while one is
  RECENT (#{div(@iterative_scan_last_conclusive_ttl_ms, 60_000)} minutes), and FAILS CLOSED
  otherwise — so the < 0.8 guarantee self-heals within that window after a failover onto an
  older pgvector even if every probe there is inconclusive.

  BOTH verdicts are cached, and both EXPIRE:

    * a CONCLUSIVE verdict for #{div(@iterative_scan_cache_ttl_ms, 60_000)} minutes, so a backend change under the
      node (replica failover onto an older pgvector, extension downgrade) self-heals on the
      next window instead of pinning a stale `true` — which would keep emitting a GUC the new
      backend rejects, 500-ing every ANN read until a redeploy;
    * an INCONCLUSIVE probe (pool checkout timeout, sandbox ownership blip, DB restart) as a
      short NEGATIVE cache. Not caching it at all was worse than a stale verdict: the
      conditions that make the probe inconclusive are exactly HeavyReadRepo saturation, so an
      uncached `:inconclusive` added one extra pool checkout AND one warning to EVERY ANN read
      precisely during the incident. The TTL is the full window once a real verdict is behind
      it; while the verdict is a fail-closed GUESS (no conclusive probe to reuse) it starts at
      #{@iterative_scan_unknown_ttl_ms}ms and DOUBLES per consecutive guess up to that window,
      so a single boot-time blip cannot pin the operator's lever OFF for a whole minute and a
      sustained incident still converges on one probe per window.
  """
  @spec iterative_scan_supported?() :: boolean()
  def iterative_scan_supported? do
    case :persistent_term.get({__MODULE__, :iterative_scan_supported}, :unknown) do
      {verdict, expires_at} when is_boolean(verdict) ->
        if now_ms() < expires_at, do: verdict, else: reprobe(verdict)

      _unknown ->
        probe_and_cache()
    end
  end

  # Best-effort single-flight: hold an expired FAIL-CLOSED verdict for one probe budget BEFORE
  # probing, so the concurrent ANN reads that also see it expire read that value instead of
  # each taking their own checkout on the small heavy-read pool — a stampede that lands ahead
  # of `TenantGate`'s shed (see `probe_iterative_scan_support/0`). That is the case worth
  # suppressing: an expired verdict is `false` precisely when the pool is saturated.
  #
  # An expired `true` is NOT republished. Re-serving it emits `SET LOCAL hnsw.iterative_scan`
  # for that window against a backend that may have CHANGED under us (replica failover onto
  # pgvector < 0.8, extension downgrade), which raises inside `run_timed_transaction/5` and
  # 500s every concurrent ANN read — reopening, through the suppression, the exact window the
  # verdict's TTL exists to close, and bypassing the recency bound `inconclusive_verdict/2`
  # applies on the slow path. A healthy backend is also where the stampede costs least: the
  # probe is a sub-millisecond `pg_extension` lookup there.
  #
  # A cold VM (no entry at all) still probes concurrently; that is once per boot.
  defp reprobe(false) do
    cache_iterative_scan_verdict(false, @probe_timeout_ms)
    probe_and_cache()
  end

  defp reprobe(true), do: probe_and_cache()

  defp probe_and_cache do
    case probe_iterative_scan_support() do
      {:ok, supported, version} ->
        maybe_warn_unsupported(supported, version)
        cache_iterative_scan_verdict(supported, @iterative_scan_cache_ttl_ms)
        :persistent_term.put({__MODULE__, :iterative_scan_last_conclusive}, {supported, now_ms()})
        reset_guess_ttl()
        supported

      {:inconclusive, reason, class} ->
        inconclusive_verdict(reason, class)
    end
  end

  # An inconclusive probe answers "I could not ask", never "the extension is missing".
  # Collapsing it to `false` was wrong in the one direction that is silent: the operator
  # has iterative scan ON, a probe blips, and the ANN read runs at the pgvector default OFF
  # — under-returning rows with nothing in the response saying so. A RECENT conclusive
  # verdict is a far better answer than a fresh guess.
  #
  # `false` remains the answer when we have never once succeeded, or when the last success is
  # older than the reuse window (the backend CAN change under us — see
  # `@iterative_scan_last_conclusive_ttl_ms`). Those are the genuine unknowns and the only
  # place fail-closed is the safe reading.
  defp inconclusive_verdict(reason, class) do
    case last_conclusive_verdict() do
      {:ok, verdict} ->
        maybe_log_inconclusive(
          class,
          "hnsw.iterative_scan capability probe was inconclusive (#{reason}) — " <>
            "reusing the last CONCLUSIVE verdict (#{verdict})"
        )

        if cacheable_inconclusive?(class) do
          cache_iterative_scan_verdict(verdict, @iterative_scan_negative_ttl_ms)
        end

        verdict

      :none ->
        maybe_log_inconclusive(
          class,
          "hnsw.iterative_scan capability probe was inconclusive (#{reason}) and no RECENT " <>
            "conclusive verdict is on record — failing closed"
        )

        if cacheable_inconclusive?(class) do
          cache_iterative_scan_verdict(false, next_guess_ttl_ms())
        end

        false
    end
  end

  @guess_ttl_key {__MODULE__, :iterative_scan_guess_ttl}

  # The TTL for THIS fail-closed guess, doubling the one after it up to the full negative
  # window. The write is skipped once the cap is reached, because `:persistent_term.put/2`
  # triggers a VM-global GC whenever it REPLACES a value — the cost that makes a hot guess
  # cadence expensive in the first place.
  defp next_guess_ttl_ms do
    ttl = :persistent_term.get(@guess_ttl_key, @iterative_scan_unknown_ttl_ms)
    next = min(ttl * 2, @iterative_scan_negative_ttl_ms)
    if next != ttl, do: :persistent_term.put(@guess_ttl_key, next)
    ttl
  end

  # A CONCLUSIVE probe means the node recovered, so the short window is available again to
  # the next blip. Erase only when set, for the same global-GC reason.
  defp reset_guess_ttl do
    if :persistent_term.get(@guess_ttl_key, nil), do: :persistent_term.erase(@guess_ttl_key)
    :ok
  end

  # Bound the log cost on the ANN hot path. An UNCACHEABLE class re-probes on every read, so
  # logging unconditionally put one warning per ANN read into the incident it was meant to
  # describe — the storm the negative cache exists to prevent, reintroduced through the
  # logger. One line per class per window is enough to see it in the logs.
  #
  # A MISSING key must EMIT, hence the `:never` sentinel rather than a `0` default: `now_ms/0`
  # is `System.monotonic_time/1`, which the BEAM deliberately starts at a large NEGATIVE value,
  # so `now_ms() >= 0` is false for the VM's whole life — a `0` default did not throttle the
  # warning, it deleted it, in exactly the incident it exists to describe.
  defp maybe_log_inconclusive(class, message) do
    key = {__MODULE__, :iterative_scan_warned, class}
    deadline = :persistent_term.get(key, :never)

    if deadline == :never or now_ms() >= deadline do
      :persistent_term.put(key, now_ms() + @iterative_scan_negative_ttl_ms)
      Logger.warning(message)
    end

    :ok
  end

  # Written ONLY by a conclusive probe, stamped with WHEN: it records what the backend
  # actually said, which is the fact we want to fall back to precisely when we cannot ask
  # again — but only while that fact is still plausibly true of the connected backend, so a
  # persistently unaskable one falls closed rather than replaying a stale verdict forever.
  # This is the fallback for "the probe failed", not a second source of truth for "what is
  # supported": the live cache above is still the answer whenever it has one.
  defp last_conclusive_verdict do
    case :persistent_term.get({__MODULE__, :iterative_scan_last_conclusive}, :none) do
      {verdict, at} when is_boolean(verdict) and is_integer(at) ->
        if now_ms() - at < @iterative_scan_last_conclusive_ttl_ms, do: {:ok, verdict}, else: :none

      _none ->
        :none
    end
  end

  # The negative cache defends against HeavyReadRepo SATURATION: under load the probe is
  # inconclusive precisely when the pool is exhausted, so re-probing every read would add a
  # checkout and a warning per ANN read during the incident. That reasoning applies to pool
  # and connection failures — and to nothing else.
  #
  # Three classes are therefore NEVER cached, and for one shared reason: caching `false` pins
  # iterative scan OFF for the whole VM for a window, and now that `config/test.exs` pins it ON so
  # the suite matches prod, a single blip silently reconfigures every ANN read in the run and
  # re-arms the `left: []` recall flake that pin exists to prevent.
  #
  #   * `:ownership` — a sandbox test-harness artifact that cannot occur in prod and says
  #     nothing about the connected pgvector's version.
  #   * `:transaction` — the backend ANSWERED but the connection was poisoned (25P02 after a
  #     deliberate constraint-violation or 57014 test). Also not backend pressure, and also
  #     silent about the version.
  #   * `:unexpected` — a THROW escaping the probe. A code bug, so it must stay loud and
  #     re-probe rather than be pinned into the negative cache.
  #
  # `:pool` (checkout timeouts, connection errors) IS the saturation case the negative cache
  # was built for, so it stays cached in prod — but NOT under the sandbox pool, where routine
  # full-suite connection exhaustion is documented and would produce exactly the suite-wide,
  # silently-wrong configuration above rather than the incident-cost saving it buys in prod.
  #
  # Decided on the CLASS the probe returns, never on a substring of the formatted log tag:
  # that coupling was invisible from both sites and would have failed OPEN (silently
  # re-enabling the negative cache) the moment the tag's wording moved.
  defp cacheable_inconclusive?(:pool), do: not sandbox_pool?()
  defp cacheable_inconclusive?(_class), do: false

  defp sandbox_pool? do
    Application.get_env(:loopctl, repo(), [])[:pool] == Ecto.Adapters.SQL.Sandbox
  end

  defp cache_iterative_scan_verdict(verdict, ttl_ms) do
    :persistent_term.put({__MODULE__, :iterative_scan_supported}, {verdict, now_ms() + ttl_ms})
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp maybe_warn_unsupported(true, _version), do: :ok

  defp maybe_warn_unsupported(false, :not_installed) do
    Logger.warning(
      "hnsw.iterative_scan is enabled but the pgvector extension is NOT INSTALLED on the " <>
        "connected backend — the setting is a NO-OP (this is not a version problem: " <>
        "CREATE EXTENSION vector first)"
    )
  end

  defp maybe_warn_unsupported(false, version) do
    Logger.warning(
      "hnsw.iterative_scan is enabled but the connected pgvector (#{version}) is older than " <>
        "#{@iterative_scan_min_version |> Tuple.to_list() |> Enum.join(".")} — " <>
        "the setting is a NO-OP until the extension is upgraded"
    )
  end

  # `{:ok, boolean, version}` = the backend answered (`version` is the raw extversion, or
  # `:not_installed` when the extension is absent); `{:inconclusive, reason, class}` = we
  # could not tell. `reason` is a STABLE TAG for the LOG, never the raw error struct — an
  # inspected `Postgrex.Error`/`DBConnection.ConnectionError` carries backend host / database
  # / role into the log stream for no diagnostic gain here (the probed SQL is a constant).
  # `class` is what `cacheable_inconclusive?/1` DECIDES on, so the caching policy never
  # depends on how the tag happens to be worded.
  @spec probe_iterative_scan_support() ::
          {:ok, boolean(), String.t() | :not_installed}
          | {:inconclusive, String.t(), :ownership | :transaction | :pool | :unexpected}
  defp probe_iterative_scan_support do
    # TIGHT timeout, because this round trip runs from `opts/1` — i.e. BEFORE `TenantGate`
    # can shed and before any `SET LOCAL statement_timeout` applies. DBConnection derives the
    # checkout DEADLINE from PER-ATTEMPT `:timeout` (`Holder.abs_timeout/2`), and
    # `savepoint_first_probe/0` can take two attempts, so each gets HALF
    # (#{@probe_attempt_timeout_ms}ms) and `@probe_timeout_ms` stays exactly the bound on how
    # long a probe may queue on a saturated heavy-read pool ahead of the gate whose whole job
    # is to shed before the checkout. A `pg_extension` lookup is sub-millisecond on a healthy
    # pool; needing more than that IS the saturation signal, and failing closed there
    # (iterative scan off for this read) is cheaper than every concurrent ANN request
    # queueing for seconds in front of the shed.
    #
    # `mode: :savepoint` WHENEVER the connection is inside a transaction (the normal shape
    # under the test sandbox): without it a SERVER-RETURNED error here — a 57014 cancel from a
    # leaked `SET LOCAL statement_timeout`, or any other `Postgrex.Error` — aborts the
    # ENCLOSING transaction (25P02), so every later statement fails over a query it never
    # issued while the `rescue`/`catch` below report a clean `:inconclusive`. That is the
    # hazard `LocalGuc.do_capture/2` guards against, on the same hot path. What savepoint mode
    # does NOT cover is the CLIENT-side deadline above: an `@probe_attempt_timeout_ms` expiry
    # is a DBConnection deadline, and Postgrex DISCONNECTS the connection on it
    # (`Postgrex.Protocol.msg_recv/3`) — there is no 57014 and no `ROLLBACK TO SAVEPOINT`; the
    # enclosing transaction dies with the connection.
    #
    # The question is put to the CONNECTION (`savepoint_first_probe/0`), not to
    # `repo().in_transaction?()`: that reads a per-process dict entry set only by
    # `Repo.transaction`/`Repo.checkout`, which `Sandbox.start_owner!` never sets — the same
    # blindness documented at `run_timed_transaction/5` — so gating on it left the protection
    # DEAD in the one shape that has an enclosing transaction to poison, while prod (`opts/1`
    # runs outside any transaction) took the plain branch either way.
    case savepoint_first_probe() do
      {:ok, %{rows: [[version]]}} when is_binary(version) ->
        {:ok, version_at_least?(version, @iterative_scan_min_version), version}

      {:ok, %{rows: []}} ->
        # The extension is genuinely absent — conclusive, and no ANN index exists either.
        {:ok, false, :not_installed}

      other ->
        {:inconclusive, probe_failure_tag(other), inconclusive_class(other)}
    end
  rescue
    error ->
      {:inconclusive, "raised:" <> inspect(error.__struct__), inconclusive_class(error)}
  catch
    # DBConnection/Postgrex EXIT rather than raise when the pool is not started (`:noproc`)
    # or wedged (`{:timeout, {GenServer, :call, _}}`). Without this clause the exit
    # propagates out of `opts/1` and aborts the caller's ANN read — the OPPOSITE of the
    # documented fail-closed guarantee. That IS the saturation case, so it keeps `:pool`.
    :exit, reason ->
      {:inconclusive, "exit:" <> exit_tag(reason), :pool}

    # A THROW is caught for the same reason (it is the third non-local exit kind, and
    # enumerating two of three is how this class of hole keeps reappearing) but NOT
    # classified `:pool`: nothing on this path throws today, so a thrown term is a CODE bug,
    # not backend pressure, and `:pool` is the one class `cacheable_inconclusive?/1` lets
    # into the negative cache — which would pin iterative scan OFF VM-wide for the negative
    # TTL over a bug, the exact silent fleet-wide disabling that cache is fenced against.
    :throw, value ->
      {:inconclusive, "throw:" <> exit_tag(value), :unexpected}
  end

  @probe_sql "SELECT extversion FROM pg_extension WHERE extname = 'vector'"

  # Ask for the savepoint, and retry PLAINLY on the one refusal that means there was no
  # transaction to protect. Postgrex refuses savepoint mode on an idle connection
  # (`Postgrex.Protocol.transaction_error/2`) with `%DBConnection.TransactionError{status:
  # :idle}` and no round trip, so prod's shape costs TWO CHECKOUTS and never a query — which
  # is why each attempt gets `@probe_attempt_timeout_ms` (half the budget) rather than the
  # whole of `@probe_timeout_ms`: the PAIR is what queues ahead of `TenantGate`'s shed.
  #
  # The OTHER refusal (`status: :error`, a connection already poisoned by an earlier
  # statement) is NOT retried: the plain query would only return the 25P02 it replaces.
  # `inconclusive_class/1` classifies it `:transaction` for exactly that reason.
  #
  # DO NOT drop the retry and pass `mode: :savepoint` alone to match `LocalGuc.do_capture/2`.
  # That sibling needs no retry because it only ever runs INSIDE a transaction; this one does
  # not. A review round proposed exactly that, on the theory that #535 had disproved the
  # idle-refusal premise. It had not: the refusal is an ERROR TUPLE, so without the retry it
  # falls to the caller's `other ->` branch and reports `:inconclusive` — on EVERY prod probe
  # — which `inconclusive_verdict/2` then resolves with no conclusive verdict to reuse,
  # silently disabling iterative scan fleet-wide. Precisely the failure #535 fixed.
  # `test/loopctl/heavy_read_savepoint_probe_test.exs` pins the refusal AND the sandbox shape
  # where `in_transaction?/0` lies, so neither premise can be re-litigated from memory.
  defp savepoint_first_probe do
    case repo().query(@probe_sql, [], timeout: @probe_attempt_timeout_ms, mode: :savepoint) do
      {:error, %DBConnection.TransactionError{status: :idle}} ->
        repo().query(@probe_sql, [], timeout: @probe_attempt_timeout_ms)

      result ->
        result
    end
  end

  # Public only so the negative-cache decision is directly testable: it is a pure function
  # of the probe's error, and getting it wrong is silent — the cost shows up as a re-probe
  # storm during an incident, which is exactly when nobody is reading this code.
  @doc false
  @spec inconclusive_class(term()) :: :ownership | :transaction | :pool
  def inconclusive_class({:error, error}), do: inconclusive_class(error)
  def inconclusive_class(%DBConnection.OwnershipError{}), do: :ownership

  # Classify on the SQLSTATE, not on the struct module. `:transaction` means one specific
  # thing — the connection was already poisoned by an EARLIER statement (25P02), which is a
  # test-harness artifact of a deliberate constraint-violation or cancellation test and says
  # nothing about backend pressure. Every OTHER Postgrex error IS the pressure case the
  # negative cache was built for: 57014 statement timeout, 53300 too_many_connections,
  # 57P01 admin shutdown. Matching the whole struct swept all of them into the one class
  # that is never cached, so a real production incident re-probed on every ANN read — the
  # exact storm the cache exists to bound.
  def inconclusive_class(%Postgrex.Error{postgres: %{code: :in_failed_sql_transaction}}),
    do: :transaction

  # The SAME poisoned-connection fact, in the shape `savepoint_first_probe/0` now surfaces it:
  # Postgrex refuses `mode: :savepoint` on an ABORTED connection before sending anything
  # (`Postgrex.Protocol.parse_describe/3`), so the 25P02 above never reaches us there. Without
  # this clause that refusal fell to the `:pool` catch-all and got NEGATIVE-CACHED in prod —
  # a fail-closed verdict from a test-harness artifact pinning iterative scan off VM-wide,
  # which is precisely what the `:transaction` class exists to prevent. (`status: :idle` never
  # reaches here: it is the retried refusal.)
  def inconclusive_class(%DBConnection.TransactionError{status: :error}), do: :transaction

  def inconclusive_class(%Postgrex.Error{}), do: :pool
  def inconclusive_class(_error), do: :pool

  defp probe_failure_tag({:error, %{__struct__: mod}}), do: "query_error:" <> inspect(mod)
  defp probe_failure_tag({:error, reason}) when is_atom(reason), do: "query_error:#{reason}"
  defp probe_failure_tag(_other), do: "unexpected_result"

  # The LAST private copy of the exit tagger, now delegating to the shared
  # `Loopctl.ExitTag`. The four clauses this replaces produced the same string for every
  # shape they actually named (`{:timeout, _}`, `:noproc`, any atom); they differed only in
  # lacking the crash-PROPAGATION clause — a pooled process that died of an exception rather
  # than being absent, which they degraded to the catch-all. The catch-all string moves
  # `"other"` -> `"unknown"`; nothing asserts either, and this tag reaches only the cached
  # inconclusive-reason string, never a metric label.
  defp exit_tag(reason), do: ExitTag.tag(reason)

  @doc """
  Compare a `"MAJOR.MINOR[.PATCH]"` pgvector extversion against a `{maj, min, patch}` floor.
  Malformed / non-numeric versions FAIL CLOSED (`false`), never raise.
  """
  @spec version_at_least?(String.t(), {non_neg_integer(), non_neg_integer(), non_neg_integer()}) ::
          boolean()
  def version_at_least?(version, {_, _, _} = floor) when is_binary(version) do
    case parse_version(version) do
      {_, _, _} = parsed -> parsed >= floor
      :error -> false
    end
  end

  defp parse_version(version) do
    case version |> String.split(".") |> Enum.take(3) |> Enum.map(&Integer.parse/1) do
      [{maj, _}, {min, _}, {patch, _}] -> {maj, min, patch}
      [{maj, _}, {min, _}] -> {maj, min, 0}
      _ -> :error
    end
  end

  # The per-endpoint override if a positive int, else the pool-wide default. Always a
  # positive int → every heavy read runs under a SET LOCAL statement_timeout (the
  # pgbouncer-safe replacement for the rejected startup `:parameters`).
  defp statement_timeout_for(endpoint) do
    case statement_timeout_override(endpoint) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> default_statement_timeout()
    end
  end

  # The pool-wide default server-side statement_timeout (ms). Defensive: a missing or
  # mis-typed (`nil`/0/negative) `:heavy_read_statement_timeout_ms` falls back to 10s rather
  # than yielding a non-positive value that would defeat the always-timed invariant.
  defp default_statement_timeout do
    case Application.get_env(:loopctl, :heavy_read_statement_timeout_ms, 10_000) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 10_000
    end
  end

  defp statement_timeout_override(endpoint) do
    :loopctl
    |> Application.get_env(:heavy_read_statement_timeout_overrides, %{})
    |> Map.get(endpoint)
  end

  @doc """
  Like `Repo.all/2`, but requires a `tenant_id` and a query whose every base-table
  source is scoped to it. Raises `ArgumentError` otherwise.

  A `:statement_timeout` (positive ms) option sets the server-side timeout for THIS read
  via a `SET LOCAL` inside a transaction (US-27.4). When omitted it defaults to the
  pool-wide `:heavy_read_statement_timeout_ms` (10s) — so EVERY heavy read is protected
  (there is no un-timed "pool default" path: pgbouncer rejects a startup-`:parameters`
  statement_timeout, so the timeout MUST be applied per-read via SET LOCAL — US-27.13).
  """
  @spec all(binary(), Ecto.Queryable.t(), keyword()) ::
          [term()] | {:error, :heavy_read_overloaded}
  def all(tenant_id, queryable, opts \\ []) do
    # `Keyword.pop/3` with a default cleanly distinguishes "absent → pool default" from a
    # PRESENT value (which is validated as a positive int below) — unlike `st || default`,
    # which would silently treat an explicit `0` as truthy and an explicit `nil` as "use
    # default", muddying the always-timed contract.
    {st, opts} = Keyword.pop(opts, :statement_timeout, default_statement_timeout())
    {ef, opts} = Keyword.pop(opts, :hnsw_ef_search, nil)
    {iter, opts} = Keyword.pop(opts, :hnsw_iterative_scan, nil)
    {on_overload, opts} = Keyword.pop(opts, :on_overload, :raise)
    query = guard!(tenant_id, queryable)
    read_repo = repo_for(endpoint(opts))

    gated(tenant_id, opts, on_overload, fn ->
      with_statement_timeout(read_repo, st, ef, iter, fn -> read_repo.all(query, opts) end)
    end)
  end

  @doc "Like `Repo.one/2`, with the same tenant-scoping guard and `:statement_timeout` as `all/3`."
  @spec one(binary(), Ecto.Queryable.t(), keyword()) ::
          term() | nil | {:error, :heavy_read_overloaded}
  def one(tenant_id, queryable, opts \\ []) do
    {st, opts} = Keyword.pop(opts, :statement_timeout, default_statement_timeout())
    {ef, opts} = Keyword.pop(opts, :hnsw_ef_search, nil)
    {iter, opts} = Keyword.pop(opts, :hnsw_iterative_scan, nil)
    {on_overload, opts} = Keyword.pop(opts, :on_overload, :raise)
    query = guard!(tenant_id, queryable)
    read_repo = repo_for(endpoint(opts))

    gated(tenant_id, opts, on_overload, fn ->
      with_statement_timeout(read_repo, st, ef, iter, fn -> read_repo.one(query, opts) end)
    end)
  end

  @doc """
  Like `all/3`, but for AGENT-MEMORY heavy reads: additionally requires an explicit
  `subject_id` scope (US-28.2).

  Memory rows on the BYPASSRLS heavy-read pool are isolated within a tenant by
  `subject_id` at the APPLICATION level (not RLS), so — exactly as `tenant_id`
  needs a structural backstop here — `subject_id` needs one too. This raises
  unless BOTH hold:

    * every base-table source is tenant-scoped (the existing `guard!/2`), AND
    * the OUTERMOST query carries a conjunctive `x.subject_id == ^subject_id`
      equality bound to the passed `subject_id`.

  The subject predicate is required on the OUTER query (not recursively on every
  source) BY DESIGN: the index-safe HNSW recall (US-28.2 AC-28.2.3) must keep
  `subject_id` OFF the inner ANN subquery (a selective `(tenant_id, subject_id)`
  btree there defeats the pgvector index — #170/#172), and post-filters subject on
  the over-fetched pool. Requiring subject on the final output guarantees no
  cross-subject row is ever RETURNED, which is what the isolation boundary needs;
  tenant remains enforced on every source (the cross-tenant boundary).
  """
  @spec all_memory(binary(), binary(), Ecto.Queryable.t(), keyword()) ::
          [term()] | {:error, :heavy_read_overloaded}
  def all_memory(tenant_id, subject_id, queryable, opts \\ []) do
    {st, opts} = Keyword.pop(opts, :statement_timeout, default_statement_timeout())
    {ef, opts} = Keyword.pop(opts, :hnsw_ef_search, nil)
    {iter, opts} = Keyword.pop(opts, :hnsw_iterative_scan, nil)
    {on_overload, opts} = Keyword.pop(opts, :on_overload, :raise)
    query = guard_memory!(tenant_id, subject_id, queryable)
    read_repo = repo_for(endpoint(opts))

    gated(tenant_id, opts, on_overload, fn ->
      with_statement_timeout(read_repo, st, ef, iter, fn -> read_repo.all(query, opts) end)
    end)
  end

  # --- US-37.5: per-tenant cost-weighted in-flight limiter ---

  # Wrap a heavy read with the per-tenant, cost-weighted in-flight gate
  # (`Loopctl.HeavyRead.TenantGate`): reserve `weight` of the tenant's budget BEFORE
  # the pool checkout, run, then RELEASE in an `after` so a query that raises (a
  # statement_timeout CANCEL, a DB error) or times out never leaks budget. The weight
  # is derived from the endpoint carried in `opts`' `telemetry_options` (heavy
  # vector/analytic reads cost more than light ones); the cap (K) is the node-local
  # per-tenant slice from config.
  #
  # Over the cap the acquire sheds the read (never a pool-exhaustion crash for OTHER
  # tenants): `on_overload: :raise` (the default, for API reads) raises
  # `OverloadedError` → a 429 with the app error envelope; `on_overload: :tag` (search
  # callers that keyword-fall-back) returns `{:error, :heavy_read_overloaded}`. The
  # gate itself FAILS OPEN on a limiter fault (allows the read), so a broken gate never
  # blocks all heavy reads.
  defp gated(tenant_id, opts, on_overload, fun) do
    weight = TenantGate.weight_for(endpoint(opts))

    case TenantGate.acquire(tenant_id, weight, TenantGate.cap()) do
      :ok ->
        try do
          fun.()
        after
          TenantGate.release(tenant_id, weight)
        end

      {:error, :heavy_read_overloaded} = err ->
        shed(on_overload, err, tenant_id)
    end
  end

  defp shed(:tag, err, _tenant_id), do: err

  defp shed(:raise, _err, tenant_id) do
    raise Loopctl.HeavyRead.OverloadedError, tenant_id: tenant_id
  end

  # The endpoint atom `opts/1` stamps into `telemetry_options` — the natural per-query
  # weight key. Absent (a bare call with no `opts/1`) → nil → TenantGate weights it light.
  defp endpoint(opts) do
    opts
    |> Keyword.get(:telemetry_options, [])
    |> Keyword.get(:endpoint)
  end

  # Run `fun` under a per-read SET LOCAL statement_timeout on `read_repo` (US-38.1: the
  # caller-resolved pool — the primary for consistency-coupled endpoints, else the
  # replica-capable heavy-read pool). There is NO un-timed path: `all/one` always resolve a
  # positive default, and a non-positive/`nil` value (an explicit mis-call) raises rather than
  # silently running un-timed (US-27.13: every heavy read MUST carry a server-side timeout
  # since the pgbouncer-rejected startup `:parameters` lever is gone).
  defp with_statement_timeout(read_repo, ms, ef, iter, fun) when is_integer(ms) and ms > 0 do
    case run_timed_transaction(read_repo, ms, ef, iter, fun) do
      {:ok, result} ->
        result

      # A heavy read aborts only via an explicit Repo.rollback (the timeout CANCEL itself is
      # a raised Postgrex.Error that propagates as-is to the DBErrorBackstop). Keep the
      # message opaque — never interpolate the rollback reason, which could carry raw SQL /
      # vector text and defeat the US-27.3 sanitization contract.
      {:error, _reason} ->
        raise "heavy read aborted (transaction rolled back)"
    end
  end

  defp with_statement_timeout(_read_repo, ms, _ef, _iter, _fun) do
    raise ArgumentError,
          ":statement_timeout (got #{inspect(ms)}) must be a positive integer (ms)"
  end

  # A transaction on `read_repo` that first scopes `SET LOCAL statement_timeout` to THIS
  # transaction (pgbouncer-safe, US-27.13), then — for a pgvector-ANN read (US-38.4) —
  # `SET LOCAL hnsw.ef_search` in the SAME transaction, then runs `fun`. Mirrors the
  # public `transaction/2` SET LOCAL, but pinned to the caller-resolved read repo so a
  # primary-pinned read (US-38.1) both times AND executes on the primary.
  defp run_timed_transaction(read_repo, ms, ef, iter, fun) do
    # NESTED-CALL LEAK (the long-running embedding-test flake). `SET LOCAL` is scoped to the
    # TOP-LEVEL transaction, not to a savepoint, so a nested read's savepoint COMMIT merges
    # its aggressive `statement_timeout` into the enclosing transaction and 57014s unrelated
    # later statements. `LocalGuc.scoped/3` captures and puts the GUCs back — see its
    # moduledoc for why capture is `current_setting/2` and restore runs in an `after`.
    #
    # Deliberately UNCONDITIONAL: `read_repo.in_transaction?/0` cannot see the nesting that
    # matters. It reads a per-repo process-dict entry set only by `Repo.transaction`/
    # `Repo.checkout`, which `Sandbox.start_owner!` never sets — so gating on it made this
    # restore dead code in exactly the sandboxed nesting it was written for. The cost when
    # NOT nested is two round trips on a transaction that already does three or more.
    read_repo.transaction(fn ->
      LocalGuc.scoped(read_repo, captured_gucs(ef, iter), fn ->
        read_repo.query!("SET LOCAL statement_timeout = #{ms}")
        maybe_set_ef_search(read_repo, ef)
        maybe_set_iterative_scan(read_repo, iter)
        fun.()
      end)
    end)
  end

  # Capture exactly the GUCs this read is about to `SET LOCAL` — a non-ANN read must not
  # pay for (or restore) a pgvector knob it never touches.
  defp captured_gucs(ef, iter) do
    ["statement_timeout"] ++
      if(is_integer(ef), do: ["hnsw.ef_search"], else: []) ++
      if(is_binary(iter), do: ["hnsw.iterative_scan", "hnsw.max_scan_tuples"], else: [])
  end

  # `SET LOCAL hnsw.ef_search = N` for an ANN read (US-38.4). Only fired when the caller
  # (via `HeavyRead.opts/1` for an `ann_endpoints/0` endpoint) supplies a positive integer
  # — non-ANN reads pass `nil` and set nothing. The value is pre-clamped to pgvector's
  # accepted `[1, 1000]` by `hnsw_ef_search/0`, and is an integer (not user text), so the
  # interpolation is injection-safe. Transaction-scoped, so it resets at COMMIT and never
  # leaks across pooled checkouts. pgvector accepts setting this GUC before the vector
  # module has loaded in the backend (namespaced placeholder), and the value applies when
  # the cosine-distance operator in `fun` loads it — the pgvector-documented order.
  defp maybe_set_ef_search(_read_repo, nil), do: :ok

  defp maybe_set_ef_search(read_repo, ef) when is_integer(ef) and ef > 0 do
    read_repo.query!("SET LOCAL hnsw.ef_search = #{ef}")
  end

  # `SET LOCAL hnsw.iterative_scan = <mode>` + a bounded `hnsw.max_scan_tuples` for an ANN
  # read (#488): when enabled, HNSW keeps scanning past the initial `ef_search` batch until
  # the LIMIT is filled with rows that pass the residual `tenant_id` filter — closing the
  # cross-tenant post-ANN-filter under-return. Fired ONLY when an operator has turned it on;
  # `mode` is a validated literal from the fixed `@hnsw_iterative_scan_modes` table (never
  # operator text), so the interpolation is injection-safe. `max_scan_tuples` is an
  # integer clamped by `hnsw_max_scan_tuples/0`. Transaction-scoped (resets at COMMIT); `nil`
  # (the default OFF) sets nothing, so a pgvector < 0.8 backend without the GUC is never
  # touched. Both GUCs are pgvector custom GUCs settable before the vector module loads in
  # the backend, applied when the ANN operator in `fun` runs — the same order ef_search uses.
  defp maybe_set_iterative_scan(_read_repo, nil), do: :ok

  defp maybe_set_iterative_scan(read_repo, mode)
       when mode in ["relaxed_order", "strict_order"] do
    read_repo.query!("SET LOCAL hnsw.iterative_scan = #{mode}")
    read_repo.query!("SET LOCAL hnsw.max_scan_tuples = #{hnsw_max_scan_tuples()}")
  end

  @doc """
  Like `Repo.stream/2`, with the same tenant-scoping guard. Must run inside a
  `transaction/2` — Ecto streams require an enclosing transaction (enumerating the
  returned stream outside one raises), which is also what scopes a per-transaction
  `SET LOCAL statement_timeout`.

  NB: the "every heavy read is timed" invariant applies to `all/3` / `one/3` (which
  default the timeout). `stream/3` and a bare `transaction/2` do NOT auto-apply one — a
  caller MUST pass `:statement_timeout` to `transaction/2` (this is the export lever) so the
  enclosed `stream/3` reads run timed. Don't add an un-timed `transaction/2` heavy read.

  NOTE: the US-27.16 streamed EXPORT does NOT use this — it pages with the US-27.9a
  keyset cursor via `all/3` (short read per page, connection RELEASED between pages)
  precisely to AVOID holding one transaction (and `xmin`) for the whole client-paced
  download. `stream/3` + `transaction/2` are reserved for a future async/Oban export
  job that builds to object storage off the request path.

  ## GATE EXEMPTION (US-37.5) — deliberate, and the future caller's responsibility

  Unlike `all/3` / `one/3` / `all_memory/4`, `stream/3` is NOT wrapped in the per-tenant
  `TenantGate` in-flight limiter. Wrapping it correctly is not a simple acquire→run→release
  `after`: a stream returns a LAZY `Enumerable` enumerated later inside an enclosing
  `transaction/2`, so the pool connection is held for the whole (client-paced) enumeration,
  not for this call — a synchronous acquire/release around this function would release the
  budget BEFORE the read actually runs. It is left ungated ON PURPOSE because there is no
  production request-path caller today (see the moduledoc: reserved for a future off-request
  async/Oban export job). That future caller MUST acquire the gate itself for the duration of
  the enumeration — `TenantGate.acquire(tenant_id, weight, TenantGate.cap())` before opening
  the transaction and `release/2` in an `after` around the whole stream — or route the read
  through `all/3` keyset paging (which IS gated) as the current export does. Do NOT add a
  request-path `stream/3` caller without one of those.
  """
  @spec stream(binary(), Ecto.Queryable.t(), keyword()) :: Enumerable.t()
  def stream(tenant_id, queryable, opts \\ []) do
    repo().stream(guard!(tenant_id, queryable), opts)
  end

  @doc """
  Delegates to the heavy-read repo's `transaction/2` (for streamed reads).

  Accepts a `:statement_timeout` option (milliseconds; must be a POSITIVE integer).
  When given, the transaction first issues `SET LOCAL statement_timeout = <ms>`,
  scoping the override to THIS transaction only — so a long-held streamed export
  (US-27.16) can run past the pool-level fast-read `statement_timeout` without
  relaxing it for everyone else. `0`/unlimited is intentionally NOT allowed (an
  unbounded hold on the small heavy pool is a DoS surface — set an explicit upper
  bound). Only supported with a 0- or 1-arity function (not an `Ecto.Multi`).

  GATE EXEMPTION (US-37.5): this bare `transaction/2` lever is NOT wrapped in the
  per-tenant `TenantGate` limiter (it has no `tenant_id` argument and holds the connection
  for the whole caller-supplied body). Like `stream/3`, it is reserved for a future
  off-request export job; that caller MUST acquire/release the gate around the transaction
  itself (see `stream/3`'s "GATE EXEMPTION" note) so a `stream/3` read taken through it is
  still bounded by the per-tenant slice. Do NOT add a request-path caller without it.

  REPLICA WRITE-SAFETY (US-38.1): unlike `all/3`/`one/3`, this lever hands the caller-supplied
  body the resolved repo (`invoke/1` → `fun.(repo())`), which — when `REPLICA_DATABASE_URL` is
  configured — is the read replica. A body is READ-ONLY BY CONTRACT: it must never call a
  write (`repo.insert!/1` etc.). This is upheld by two layers — no such writing caller exists
  in `lib/` (there is no request-path `transaction/2` caller at all), AND a real read replica
  is physically read-only and rejects writes. Keep both true: any future body stays reads-only.
  """
  @spec transaction((-> any()) | (module() -> any()) | Ecto.Multi.t(), keyword()) ::
          {:ok, any()} | {:error, any()}
  def transaction(fun_or_multi, opts \\ []) do
    case Keyword.pop(opts, :statement_timeout) do
      {nil, opts} ->
        repo().transaction(fun_or_multi, opts)

      {ms, opts}
      when is_integer(ms) and ms > 0 and
             (is_function(fun_or_multi, 0) or is_function(fun_or_multi, 1)) ->
        # Same nested-savepoint leak as `run_timed_transaction/5` — one mechanism, one
        # implementation (`Loopctl.LocalGuc`).
        LocalGuc.timed_transaction(repo(), ms, fn -> invoke(fun_or_multi) end, opts)

      {ms, _opts} ->
        raise ArgumentError,
              ":statement_timeout (got #{inspect(ms)}) requires a POSITIVE integer (ms) and a " <>
                "0/1-arity function transaction body (not an Ecto.Multi, not 0/unlimited)"
    end
  end

  defp invoke(fun) when is_function(fun, 0), do: fun.()
  defp invoke(fun) when is_function(fun, 1), do: fun.(repo())

  # --- structural tenant guard ---

  defp guard!(tenant_id, queryable) when is_binary(tenant_id) do
    query = Ecto.Queryable.to_query(queryable)

    unless query_scoped?(query, {:value, tenant_id}) do
      raise ArgumentError,
            "Loopctl.HeavyRead refuses a query not fully scoped to the given tenant (BYPASSRLS " <>
              "pool, cross-tenant leak risk). Every base-table source (#{source_tables(query)}) " <>
              "must carry a conjunctive `x.tenant_id == ^tenant_id` equality bound to the passed " <>
              "tenant_id (no OR-bypass, no unscoped join)."
    end

    query
  end

  defp guard!(tenant_id, _queryable) do
    raise ArgumentError,
          "Loopctl.HeavyRead requires a binary tenant_id as the first argument, got: " <>
            inspect(tenant_id)
  end

  # --- structural (tenant + subject) memory guard (US-28.2) ---

  defp guard_memory!(tenant_id, subject_id, queryable)
       when is_binary(tenant_id) and is_binary(subject_id) do
    # First enforce the full tenant guard on every base-table source, then require
    # a subject equality on the OUTERMOST query (see all_memory/4 for why subject is
    # NOT required recursively — it must stay off the index-ordered inner ANN).
    query = guard!(tenant_id, queryable)

    unless outer_from_scoped_by_field?(query, :subject_id, {:value, subject_id}) do
      raise ArgumentError,
            "Loopctl.HeavyRead refuses a memory query not scoped to the given subject " <>
              "(BYPASSRLS pool, cross-subject leak within a tenant). The outermost query must " <>
              "carry a conjunctive `x.subject_id == ^subject_id` equality bound to the passed " <>
              "subject_id."
    end

    query
  end

  defp guard_memory!(tenant_id, subject_id, _queryable) do
    raise ArgumentError,
          "Loopctl.HeavyRead.all_memory requires a binary tenant_id AND subject_id, got: " <>
            inspect({tenant_id, subject_id})
  end

  @doc false
  # Structural shape check (no value binding): does this query's PRIMARY OUTPUT
  # (`from`) binding carry a conjunctive `x.subject_id == ^subject` equality?
  # Exposed for the guard unit tests (companion to `filters_by_tenant?/1`).
  def filters_by_subject?(queryable) do
    queryable |> Ecto.Queryable.to_query() |> outer_from_scoped_by_field?(:subject_id, :any)
  end

  # True iff the outermost query's PRIMARY OUTPUT binding — its `from`, binding
  # index 0 — is constrained (in the outer level's own wheres/havings/join-ons, NOT
  # recursively) by a conjunctive `x.field == ^pin` equality, pin bound to the value
  # for `{:value, v}` / any pin for `:any`.
  #
  # Requiring the predicate on the OUTPUT binding — not merely SOME binding — matches
  # the tenant guard's every-output-source strength. The weaker any-binding form
  # would PASS a query whose returned `from` rows are only tenant-scoped while a
  # JOINED source happens to carry the subject predicate, and then return
  # cross-subject rows from the unscoped `from` binding on the BYPASSRLS pool. The
  # index-safe HNSW recall keeps subject OFF the inner ANN and post-filters it on the
  # outer query's `from` (a from-subquery) — so anchoring on binding 0 is exactly the
  # recall shape while closing the joined-source leak.
  defp outer_from_scoped_by_field?(%Ecto.Query{} = query, field, mode) do
    MapSet.member?(field_scoped_bindings(query, field, mode), 0)
  end

  @doc false
  # Structural shape check (no value binding): would this query pass the guard for
  # SOME tenant? Exposed for the guard unit tests.
  def filters_by_tenant?(queryable) do
    queryable |> Ecto.Queryable.to_query() |> query_scoped?(:any)
  end

  # A query is scoped iff every base-table source has a conjunctive tenant equality
  # on its binding (matching the caller for `{:value, t}`, any pin for `:any`) and
  # every subquery source is itself scoped.
  defp query_scoped?(%Ecto.Query{} = query, mode) do
    scoped = scoped_bindings(query, mode)

    Enum.all?(source_bindings(query), fn
      {idx, :table} -> MapSet.member?(scoped, idx)
      {_idx, {:sub, sub}} -> query_scoped?(sub, mode)
      # Non-schema source (raw fragment from / CTE ref): not structurally validated.
      {_idx, :other} -> true
    end)
  end

  # Each source paired with its binding index (from = 0, joins = 1, 2, … in order).
  defp source_bindings(query) do
    from_b = {0, classify(query.from && query.from.source)}

    join_b =
      query.joins
      |> Enum.with_index(1)
      |> Enum.map(fn {j, i} -> {i, classify(Map.get(j, :source))} end)

    [from_b | join_b]
  end

  defp classify(%Ecto.SubQuery{query: q}), do: {:sub, q}
  defp classify({_table, schema}) when is_atom(schema) and not is_nil(schema), do: :table
  defp classify(_), do: :other

  # Binding indices constrained by a CONJUNCTIVE `x.tenant_id == ^pin` equality in a
  # where/having/join-on (a tenant equality nested under an OR does NOT count — it
  # can re-admit other tenants). For `{:value, t}` the pin must be bound to `t`.
  defp scoped_bindings(query, mode), do: field_scoped_bindings(query, :tenant_id, mode)

  # Generalized over the scoping field (`:tenant_id` or `:subject_id`). Returns the
  # binding indices constrained by a conjunctive `x.field == ^pin` equality.
  defp field_scoped_bindings(query, field, mode) do
    exprs =
      query.wheres ++
        query.havings ++
        (query.joins |> Enum.map(& &1.on) |> Enum.reject(&is_nil/1))

    Enum.reduce(exprs, MapSet.new(), fn %{expr: expr, params: params}, acc ->
      expr
      |> and_conjuncts()
      |> Enum.flat_map(&field_binding(&1, field, params, mode))
      |> Enum.into(acc)
    end)
  end

  defp and_conjuncts({:and, _, [l, r]}), do: and_conjuncts(l) ++ and_conjuncts(r)
  defp and_conjuncts(other), do: [other]

  defp field_binding({:==, _, [l, r]}, field, params, mode) do
    cond do
      (k = field_access_binding(l, field)) && pin?(r) && pin_matches?(r, params, mode) -> [k]
      (k = field_access_binding(r, field)) && pin?(l) && pin_matches?(l, params, mode) -> [k]
      true -> []
    end
  end

  defp field_binding(_, _, _, _), do: []

  # Matches `x.field` for the SAME `field` atom passed in (the repeated `field`
  # variable in the head is an equality constraint).
  defp field_access_binding({{:., _, [{:&, _, [k]}, field]}, _, _}, field), do: k
  defp field_access_binding(_, _), do: nil

  defp pin?({:^, _, [_]}), do: true
  defp pin?(_), do: false

  defp pin_matches?({:^, _, [i]}, params, {:value, tenant_id}),
    do: match?({^tenant_id, _type}, Enum.at(params || [], i))

  defp pin_matches?(_, _, :any), do: true

  # Human-readable list of source names for the error — table names only, NO bound
  # params, so no embeddings / tenant ids / agent ids leak into logs (info disclosure).
  defp source_tables(query) do
    [query.from && query.from.source | Enum.map(query.joins, &Map.get(&1, :source))]
    |> Enum.flat_map(fn
      {table, schema} when is_atom(schema) and not is_nil(schema) -> [table]
      %Ecto.SubQuery{} -> ["<subquery>"]
      _ -> []
    end)
    |> Enum.join(", ")
  end
end
