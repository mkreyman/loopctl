defmodule Loopctl.Llm do
  @moduledoc """
  Per-tenant BYO LLM + embedding configuration + usage tracking (Epic 28 residual,
  #179; embeddings closes the operator-funded embedding-spend gap).

  loopctl is multi-tenant and **BYO-key**: every tenant supplies its OWN keys and
  pays the provider directly. loopctl fronts no cost — there is no markup, price
  table, or billing. Two SEPARATE keys are configured per tenant:

    * an **Anthropic** key for knowledge LLM work (ingest/classify/merge), and
    * an **OpenAI-compatible embedding** key for article vector embeddings +
      semantic search.

  A tenant with no Anthropic key CANNOT run tenant knowledge-LLM work:
  `resolve(tenant_id, :extraction | :classification | :merge)` returns
  `{:error, :no_api_key}` and callers fail cleanly (a 422 at the API boundary; the
  Oban worker `{:discard}`s). A tenant with no embedding key gets NO embeddings:
  `resolve(tenant_id, :embedding)` returns `{:error, :no_api_key}`, the embedding
  client refuses to call the provider, and `ArticleEmbeddingWorker` cleanly
  `{:discard}`s `{:no_embedding_key, _}` (the article is still created — it is just
  not vector-searchable until a key is set). There is intentionally NO
  global-system-key fallback for either path.

  ## Repo strategy

  Like `Loopctl.Webhooks` (the other encrypted-secret tenant context), these
  functions run from BOTH web requests and Oban workers, so they use
  `Loopctl.AdminRepo` with an EXPLICIT `tenant_id` filter on every query. RLS is
  additionally enabled on both tables (defense in depth + the repo-wide
  `rls_coverage_test` invariant). A caller only ever passes its own `tenant_id`
  (web: `current_api_key.tenant_id`; worker: the job's `tenant_id` arg), so there
  is no cross-tenant resolve.

  ## Security

  - The API key is encrypted at rest (`Loopctl.Vault.Binary`) and `redact: true`,
    so it never appears in logs/inspect.
  - It is NEVER returned by any function that feeds a serializer — only
    `resolve/2` (which hands it straight to the Anthropic client) exposes the
    plaintext. `settings_view/1` returns `has_api_key?` + a last-4 hint only.
  - Setting/rotating a key writes an audit event (WITHOUT the value).
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.HeavyRead
  alias Loopctl.Llm.Anthropic
  alias Loopctl.Llm.SettingsCache
  alias Loopctl.Llm.TenantLlmSettings
  alias Loopctl.Llm.UsageEvent

  # Server default model per operation when the tenant left that field nil. A key
  # is still MANDATORY — the default only fills the model, never the key. Haiku is
  # the cheap sensible default; a tenant overrides per-operation as they wish. The
  # embedding default is OpenAI's cheap small embedding model.
  @default_model "claude-haiku-4-5-20251001"
  @default_embedding_model "text-embedding-3-small"
  @default_models %{
    extraction: @default_model,
    classification: @default_model,
    merge: @default_model,
    embedding: @default_embedding_model
  }

  # Operations backed by the Anthropic `api_key`.
  @llm_operations [:extraction, :classification, :merge]

  @type operation :: :extraction | :classification | :merge | :embedding

  @typedoc """
  The chat provider a tenant's knowledge-LLM work runs against (US-41.3).

  `:anthropic` is the DEFAULT for every tenant that configures nothing
  (AC-41.3.7). `:openai_compatible` routes to the tenant's own
  `chat_base_url` + `chat_api_key` via `Loopctl.Llm.OpenAiChat`.
  """
  @type chat_provider :: :anthropic | :openai_compatible

  @typedoc """
  A resolved provider call target.

  `:provider` + `:base_url` were added by US-41.3. They are ADDITIVE — every
  pre-existing caller pattern-matches `%{api_key: _, model: _}`, which still
  matches. `:base_url` is the SINGLE source of the endpoint actually posted to,
  read by `Loopctl.Egress.resolved_endpoints/1` so the posture report and the
  egress guard can never vet different URLs (AC-41.4.9).
  """
  @type resolved :: %{
          api_key: String.t(),
          model: String.t(),
          provider: chat_provider() | :embedding,
          base_url: String.t() | nil
        }

  # --- Settings ---

  @doc """
  Returns the tenant's LLM settings row, or `nil` if none exists.

  The `api_key` field on the returned struct is decrypted plaintext — treat it as
  a secret. Prefer `resolve/2` for LLM call sites.

  READ-THROUGH CACHED (US-32.3): the resolved+decrypted struct (or `nil`) is served
  from a supervised ETS cache keyed by `tenant_id`, converting a per-call DB read +
  Cloak decrypt into a per-change one. On a miss it loads from the DB, caches, and
  returns; `upsert_settings/2` invalidates the entry. Signature and return shape are
  unchanged.

  The cache generation is captured BEFORE the DB load and passed to `put/3`, so a
  concurrent rotation that invalidates during the load bumps the generation and the
  (now-possibly-stale) repopulation is rejected at the next `fetch/1` — closing the
  intra-node read-through repopulation race (AC-32.3.3). Staleness bounds are
  layered: exact on the writing node, prompt cross-node via a PubSub invalidation
  broadcast, and capped by a bounded per-entry TTL for the dropped-broadcast /
  crash-window cases. See `Loopctl.Llm.SettingsCache` for the full guarantee.
  """
  @spec get_settings(Ecto.UUID.t()) :: TenantLlmSettings.t() | nil
  def get_settings(tenant_id) when is_binary(tenant_id) do
    case SettingsCache.fetch(tenant_id) do
      {:ok, value} ->
        value

      :miss ->
        generation = SettingsCache.generation(tenant_id)
        settings = load_settings(tenant_id)
        SettingsCache.put(tenant_id, settings, generation)
        settings
    end
  end

  # Direct, UNCACHED DB read of the tenant's settings row. Used on the cache-miss
  # read-through path AND by the write path (`upsert_settings/2`), which must fetch
  # the existing row uncached so a cached (possibly negative) entry can never leak
  # into the insert_or_update changeset.
  @spec load_settings(Ecto.UUID.t()) :: TenantLlmSettings.t() | nil
  defp load_settings(tenant_id) when is_binary(tenant_id) do
    AdminRepo.get_by(TenantLlmSettings, tenant_id: tenant_id)
  end

  @doc """
  Upserts the tenant's LLM settings (one row per tenant).

  `attrs` may carry any of `api_key`, `embedding_api_key`, `extraction_model`,
  `classification_model`, `merge_model`, `embedding_model` (string or atom keys).
  `tenant_id` is set programmatically. Both secret keys (when present) are stored
  encrypted and NEVER cast from params. When a key is set/rotated, an
  `llm_config.key_set` / `llm_config.embedding_key_set` audit event is written
  WITHOUT the value; every upsert writes an `llm_config.updated` event listing
  which model fields changed.

  Returns `{:ok, settings}` or `{:error, changeset}`.
  """
  @spec upsert_settings(Ecto.UUID.t(), map()) ::
          {:ok, TenantLlmSettings.t()} | {:error, Ecto.Changeset.t()}
  def upsert_settings(tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs) do
    attrs = normalize_keys(attrs)
    api_key = Map.get(attrs, :api_key)
    embedding_api_key = Map.get(attrs, :embedding_api_key)
    chat_api_key = Map.get(attrs, :chat_api_key)
    # UNCACHED read on the WRITE path: `get_settings/1` is now cached (and may hold a
    # negative `nil` entry), so fetch the existing row directly from the DB — a stale
    # or negative cached struct must never seed the insert_or_update changeset (US-32.3).
    existing = load_settings(tenant_id)

    changeset =
      (existing || %TenantLlmSettings{tenant_id: tenant_id})
      |> TenantLlmSettings.models_changeset(attrs)
      |> TenantLlmSettings.put_api_key(api_key)
      |> TenantLlmSettings.put_embedding_api_key(embedding_api_key)
      |> TenantLlmSettings.put_chat_api_key(chat_api_key)
      |> Ecto.Changeset.put_change(:tenant_id, tenant_id)

    key_set? = not is_nil(api_key)
    embedding_key_set? = not is_nil(embedding_api_key)
    chat_key_set? = not is_nil(chat_api_key)

    Multi.new()
    |> Multi.insert_or_update(:settings, changeset)
    |> Multi.merge(fn %{settings: settings} ->
      audit_multi(tenant_id, settings, changeset, %{
        api_key: key_set?,
        embedding_api_key: embedding_key_set?,
        chat_api_key: chat_key_set?
      })
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{settings: settings}} ->
        # Invalidate AFTER commit so the next read repopulates read-through with the
        # fresh row (US-32.3, AC-32.3.3). This is the sole settings-mutation path, so
        # it is the only cache-busting point. Use the CLUSTER variant: the ETS table
        # is node-local, so we bust this node synchronously AND broadcast so peer
        # nodes bust their node-local entries within a PubSub hop (the bounded TTL
        # backstops a dropped broadcast or a crash in this post-commit gap).
        SettingsCache.invalidate_cluster(tenant_id)
        {:ok, settings}

      {:error, :settings, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Resolves the tenant's API key + per-operation model for a provider call.

  For the Anthropic operations (`:extraction`, `:classification`, `:merge`) this
  resolves the `api_key`; for `:embedding` it resolves the SEPARATE
  `embedding_api_key`. Returns `{:ok, %{api_key: decrypted, model: model}}` or
  `{:error, :no_api_key}` when the tenant has no key configured for that path
  (mandatory BYO — no fallback). When the tenant left the per-operation model nil,
  the server default for that operation is used.
  """
  @spec resolve(Ecto.UUID.t(), operation()) :: {:ok, resolved()} | {:error, :no_api_key}
  def resolve(tenant_id, :embedding) when is_binary(tenant_id) do
    case get_settings(tenant_id) do
      %TenantLlmSettings{embedding_api_key: key} = settings when is_binary(key) and key != "" ->
        {:ok,
         %{
           api_key: key,
           model: model_for(settings, :embedding),
           provider: :embedding,
           base_url: nil
         }}

      _ ->
        {:error, :no_api_key}
    end
  end

  def resolve(tenant_id, operation)
      when is_binary(tenant_id) and operation in @llm_operations do
    tenant_id |> get_settings() |> resolve_chat(operation)
  end

  # US-41.3: the provider decision precedes the credential decision. Resolving the
  # key FIRST and the provider second is the cross-provider credential-leak vector
  # this ordering closes — an `openai_compatible` tenant must NEVER be handed the
  # Anthropic `api_key`, and vice versa.
  defp resolve_chat(%TenantLlmSettings{chat_provider: "openai_compatible"} = settings, operation) do
    case {settings.chat_api_key, settings.chat_base_url} do
      {key, base_url} when is_binary(key) and key != "" and is_binary(base_url) ->
        {:ok,
         %{
           api_key: key,
           model: model_for(settings, operation),
           provider: :openai_compatible,
           base_url: base_url
         }}

      _ ->
        {:error, :no_api_key}
    end
  end

  defp resolve_chat(%TenantLlmSettings{api_key: key} = settings, operation)
       when is_binary(key) and key != "" do
    {:ok,
     %{
       api_key: key,
       model: model_for(settings, operation),
       provider: :anthropic,
       base_url: Anthropic.base_url()
     }}
  end

  defp resolve_chat(_settings, _operation), do: {:error, :no_api_key}

  @doc """
  The tenant's CHAT provider, resolved WITHOUT touching any credential.

  This is the single resolution point the five tenant-aware behaviour routers
  (`Loopctl.Knowledge.ContentExtractorRouter` and siblings) consult per call. It
  is deliberately credential-free: a router must decide WHICH sibling handles the
  call before any key is read, so the Anthropic key can never be handed to the
  OpenAI-compatible client (AC-41.3.2 / AC-41.3.3).

  Returns `:anthropic` for every tenant that has configured nothing (AC-41.3.7).
  """
  @spec chat_provider(Ecto.UUID.t()) :: chat_provider()
  def chat_provider(tenant_id) when is_binary(tenant_id) do
    case get_settings(tenant_id) do
      %TenantLlmSettings{chat_provider: "openai_compatible"} -> :openai_compatible
      _ -> :anthropic
    end
  end

  @doc """
  The chat BASE URL currently resolved for `tenant_id` — the SINGLE source of the
  endpoint the chat clients actually post to.

  `Loopctl.Egress.resolved_endpoints/1` reads it from HERE rather than
  re-deriving it, so the endpoint vetted by the posture report / `local_only`
  pre-flight is always the endpoint the guard sees. A second, divergent URL
  resolution is an AC-41.4.9 review failure.
  """
  @spec chat_base_url(Ecto.UUID.t()) :: String.t()
  def chat_base_url(tenant_id) when is_binary(tenant_id) do
    case get_settings(tenant_id) do
      %TenantLlmSettings{chat_provider: "openai_compatible", chat_base_url: url}
      when is_binary(url) and url != "" ->
        url

      _ ->
        Anthropic.base_url()
    end
  end

  @doc """
  Whether the tenant has a usable Anthropic API key configured. Used by the
  ingest boundary (422 up front) and workers (discard) to enforce mandatory BYO
  WITHOUT holding the plaintext key.
  """
  @spec has_api_key?(Ecto.UUID.t()) :: boolean()
  def has_api_key?(tenant_id) when is_binary(tenant_id) do
    match?({:ok, _}, resolve(tenant_id, :extraction))
  end

  @doc """
  Whether the tenant has a usable embedding API key configured. Used by
  `ArticleEmbeddingWorker` (discard) to enforce mandatory BYO for embeddings
  WITHOUT holding the plaintext key.
  """
  @spec has_embedding_key?(Ecto.UUID.t()) :: boolean()
  def has_embedding_key?(tenant_id) when is_binary(tenant_id) do
    match?({:ok, _}, resolve(tenant_id, :embedding))
  end

  @doc """
  Whether a (sanitized) provider error is PERMANENT — it will never succeed on
  retry, so a worker should `{:discard}` rather than burn its Oban attempts on it
  (review #5). A 4xx response is a bad/revoked key or malformed request (permanent)
  EXCEPT 408 (request timeout) and 429 (rate limit), which are transient. Everything
  else (5xx, transport, timeout, crash) is transient.
  """
  @spec permanent_provider_error?(term()) :: boolean()
  # US-37.3: the throttle 4-tuple (`{:api_error, status, :provider_error,
  # retry_after}`) only ever carries a 429/503 (see `Loopctl.Provider.RetryAfter`)
  # — both transient. Classify it explicitly so the widened arity never falls
  # through to a misleading verdict.
  def permanent_provider_error?({:api_error, status, _, _}) when status in [408, 429], do: false

  def permanent_provider_error?({:api_error, status, _, _})
      when is_integer(status) and status >= 400 and status < 500,
      do: true

  def permanent_provider_error?({:api_error, status, _}) when status in [408, 429], do: false

  def permanent_provider_error?({:api_error, status, _})
      when is_integer(status) and status >= 400 and status < 500,
      do: true

  def permanent_provider_error?({:api_error, status}) when status in [408, 429], do: false

  def permanent_provider_error?({:api_error, status})
      when is_integer(status) and status >= 400 and status < 500,
      do: true

  def permanent_provider_error?(_other), do: false

  @doc """
  Records that a tenant LLM `operation` was BLOCKED for a missing BYO key
  (review #2 — the mandatory-BYO cutover needs observability). Emits a
  `Logger.warning`, a `[:loopctl, :llm, :blocked]` telemetry event, and an
  `llm.blocked_no_api_key` audit entry (with tenant_id + operation, never a key).
  Best-effort: a telemetry/audit failure never propagates to the caller.
  """
  @spec record_blocked(Ecto.UUID.t(), operation()) :: :ok
  def record_blocked(tenant_id, operation) when is_binary(tenant_id) do
    Logger.warning(
      "Loopctl.Llm: tenant=#{tenant_id} blocked op=#{operation} — no " <>
        "#{blocked_credential(operation)} configured (mandatory BYO)."
    )

    :telemetry.execute([:loopctl, :llm, :blocked], %{count: 1}, %{
      tenant_id: tenant_id,
      operation: operation,
      provider: blocked_credential_provider(operation)
    })

    Audit.create_log_entry(tenant_id, %{
      entity_type: "llm_config",
      entity_id: tenant_id,
      action: "llm.blocked_no_api_key",
      actor_type: "system",
      actor_id: nil,
      actor_label: "llm",
      new_state: %{"operation" => to_string(operation)}
    })

    :ok
  rescue
    e ->
      Logger.error("Loopctl.Llm.record_blocked failed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Records a GENUINE provider failure — a real 4xx/5xx/transport/timeout error
  returned by a provider call that WAS ACTUALLY ATTEMPTED (a key was configured and
  present). US-34.3 (AC-34.3.3)'s provider-error-rate `Loopctl.Telemetry.ScaleAlerts`
  signal windows this event.

  Distinct from `record_blocked/2`, which fires for a MISSING-key config state
  checked BEFORE any provider call — conflating the two would both false-page (a
  keyless tenant looks like a provider incident) and mask the real incident class
  (a genuine 429/5xx/transport storm on a tenant WITH a key never touches
  `record_blocked/2` at all). See `Loopctl.Telemetry.ScaleMetrics`'s "AC-34.4.3
  coordination" moduledoc note.

  Call this from EXACTLY ONE choke point per failure at each call site — currently
  `Loopctl.Knowledge.run_embedding_task/3` (`provider: "embedding"`) — the SINGLE
  guarded entry point shared by both Oban workers (`ArticleEmbeddingWorker`/
  `MemoryEmbeddingWorker`) AND every query-time embedding caller (combined/semantic
  search, novelty scoring, `Memory.recall/2`, promotion near-dup lookup), gated by
  the same `breaker_countable?/1` classification the circuit breaker uses so a
  per-tenant 4xx never contributes, and never for the circuit breaker's own
  `:circuit_open` skip — and `Loopctl.Llm.Anthropic`'s shared HTTP client
  (`provider: "anthropic"`, the ONE choke point for every Anthropic call site —
  content extraction/classification/merge/memory-promotion) — so the emitted count
  matches the actual failure count 1:1 — no double-counting.

  Emits `[:loopctl, :llm, :provider_error]` with BOUNDED metadata ONLY: `provider`
  (`"anthropic"` | `"embedding"` | `"openai_compatible"` — a FIXED set, never a
  tenant-supplied host) and `class` (`:transient` | `:permanent`, per
  `permanent_provider_error?/1`) — NEVER `tenant_id`, an article/memory id, or any
  provider response body (the caller has already run the reason through
  `Loopctl.Llm.ProviderError.sanitize/1` before classifying it). Best-effort: a
  telemetry failure never propagates to the caller (mirrors `record_blocked/2`).
  """
  @spec record_provider_error(String.t(), :transient | :permanent) :: :ok
  def record_provider_error(provider, class)
      when provider in ["anthropic", "embedding", "openai_compatible"] and
             class in [:transient, :permanent] do
    :telemetry.execute([:loopctl, :llm, :provider_error], %{count: 1}, %{
      provider: provider,
      class: class
    })

    :ok
  rescue
    e ->
      Logger.error("Loopctl.Llm.record_provider_error failed: #{Exception.message(e)}")
      :ok
  end

  # The two BYO credentials are SEPARATE — name the right one in the block log so an
  # operator isn't misled into checking the Anthropic key for an embedding block
  # (review MED #3). The structured audit already carries the exact operation.
  defp blocked_credential(:embedding), do: "embedding API key"
  defp blocked_credential(_anthropic_op), do: "Anthropic API key"

  # US-34.4 (AC-34.4.4): the ONE bounded metadata tag added to this emit site — a
  # `provider` label for the `[:loopctl, :llm, :blocked]` counter
  # (`Loopctl.Telemetry.ScaleMetrics`). Mirrors `blocked_credential/1`'s existing
  # bounded 2-way split (embedding vs Anthropic) rather than introducing a new
  # dimension, so the label stays a fixed, small set.
  defp blocked_credential_provider(:embedding), do: "embedding"
  defp blocked_credential_provider(_anthropic_op), do: "anthropic"

  @doc """
  A safe view of the tenant's settings for API responses: the model choices,
  `has_api_key` / `has_embedding_key`, and last-4 hints — NEVER a key itself.
  """
  @spec settings_view(TenantLlmSettings.t() | nil) :: map()
  def settings_view(nil) do
    %{
      has_api_key: false,
      api_key_hint: nil,
      extraction_model: nil,
      classification_model: nil,
      merge_model: nil,
      has_embedding_key: false,
      embedding_api_key_hint: nil,
      embedding_model: nil,
      chat_provider: "anthropic",
      chat_base_url: nil,
      has_chat_key: false,
      chat_api_key_hint: nil
    }
  end

  def settings_view(%TenantLlmSettings{} = s) do
    %{
      has_api_key: has_key?(s.api_key),
      api_key_hint: api_key_hint(s.api_key),
      extraction_model: s.extraction_model,
      classification_model: s.classification_model,
      merge_model: s.merge_model,
      has_embedding_key: has_key?(s.embedding_api_key),
      embedding_api_key_hint: api_key_hint(s.embedding_api_key),
      embedding_model: s.embedding_model,
      # US-41.3: the chat endpoint is NOT a secret — echoing it is the point (an
      # operator/agent must be able to confirm where tenant content is going). The
      # credential stays a `has_*` + last-4 hint like every other key.
      chat_provider: s.chat_provider || "anthropic",
      chat_base_url: s.chat_base_url,
      has_chat_key: has_key?(s.chat_api_key),
      chat_api_key_hint: api_key_hint(s.chat_api_key)
    }
  end

  # --- Usage tracking ---

  @doc """
  Records a token-usage event AFTER a successful LLM response.

  `attrs` must carry `:operation`, `:model`, `:input_tokens`, `:output_tokens`
  and may carry `:source_type` and `:article_id`. `tenant_id` and `occurred_at`
  are set programmatically. Returns `{:ok, event}` or `{:error, changeset}`.
  """
  @spec record_usage(Ecto.UUID.t(), map()) ::
          {:ok, UsageEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_usage(tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.put_new(:occurred_at, DateTime.utc_now())

    %UsageEvent{tenant_id: tenant_id}
    |> UsageEvent.create_changeset(attrs)
    |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
    |> AdminRepo.insert()
  end

  @default_summary_limit 50
  @max_summary_limit 200

  @doc """
  Aggregates a tenant's usage, grouped by operation + model + provider +
  source_type + day,
  summing input/output tokens and counting events, over an optional date range.

  Opts: `:from`, `:to` (DateTime), `:limit` (default #{@default_summary_limit},
  clamped to #{@max_summary_limit}), `:offset` (default 0). Rows are ordered
  `day desc` with an `(operation, model, source_type)` tiebreaker for a stable
  page across equal days.

  Returns `%{data: [row], meta: %{limit, offset, total_count}}` where each row is
  `%{day, operation, model, provider, source_type, input_tokens, output_tokens,
  event_count}`.
  """
  @spec usage_summary(Ecto.UUID.t(), keyword()) :: %{data: [map()], meta: map()}
  def usage_summary(tenant_id, opts \\ []) when is_binary(tenant_id) do
    limit = opts |> Keyword.get(:limit, @default_summary_limit) |> clamp_limit()
    offset = opts |> Keyword.get(:offset, 0) |> max_zero()

    # The EFFECTIVE window actually applied (review #8): `from` defaults to a
    # 90-day lookback when omitted, so echo it in meta — otherwise a caller can't
    # tell that older usage was silently excluded. `to` is nil = open-ended (now).
    effective_from = Keyword.get(opts, :from) || default_from()
    effective_to = Keyword.get(opts, :to)

    base = usage_base_query(tenant_id, effective_from, effective_to)

    grouped =
      from(e in base,
        group_by: [
          fragment("date_trunc('day', ?)", e.occurred_at),
          e.operation,
          e.model,
          e.provider,
          e.source_type
        ],
        select: %{
          day: fragment("date_trunc('day', ?)", e.occurred_at),
          operation: e.operation,
          model: e.model,
          # US-41.3 (AC-41.3.6): provider-attributed so a tenant's local-endpoint
          # spend is distinguishable from Anthropic's instead of silently blending.
          provider: e.provider,
          source_type: e.source_type,
          input_tokens: sum(e.input_tokens),
          output_tokens: sum(e.output_tokens),
          event_count: count(e.id)
        }
      )

    # This customer-facing aggregate reads the (potentially large) llm_usage_events
    # table, so route it through HeavyRead (per-read SET LOCAL statement_timeout +
    # tenant-scope guard) like the other heavy reads (review #9). The grouped
    # subquery's base carries `e.tenant_id == ^tenant_id`, so the guard passes.
    total_query = from(g in subquery(grouped), select: count(g.day))
    total = HeavyRead.one(tenant_id, total_query, HeavyRead.opts(:llm_usage)) || 0

    rows_query =
      from(g in subquery(grouped),
        order_by: [
          desc: g.day,
          asc: g.operation,
          asc: g.model,
          asc: g.source_type
        ],
        limit: ^limit,
        offset: ^offset
      )

    rows =
      tenant_id
      |> HeavyRead.all(rows_query, HeavyRead.opts(:llm_usage))
      |> Enum.map(&normalize_summary_row/1)

    %{
      data: rows,
      meta: %{
        limit: limit,
        offset: offset,
        total_count: total,
        from: effective_from,
        to: effective_to
      }
    }
  end

  # --- Private ---

  # Default the lower bound to a 90-day lookback when the caller omits `:from`, so
  # the aggregate can never unboundedly scan the whole table (review #9). An
  # explicit `:from`/`:to` is honored (the (tenant_id, occurred_at) index keeps a
  # bounded range efficient).
  @default_lookback_days 90

  defp usage_base_query(tenant_id, effective_from, effective_to) do
    from(e in UsageEvent, where: e.tenant_id == ^tenant_id)
    |> maybe_from(effective_from)
    |> maybe_to(effective_to)
  end

  defp default_from,
    do: DateTime.add(DateTime.utc_now(), -@default_lookback_days * 86_400, :second)

  defp maybe_from(query, %DateTime{} = from), do: where(query, [e], e.occurred_at >= ^from)
  defp maybe_from(query, _), do: query

  defp maybe_to(query, %DateTime{} = to), do: where(query, [e], e.occurred_at <= ^to)
  defp maybe_to(query, _), do: query

  # sum() over integers returns a Decimal; normalize to integers for the JSON view.
  defp normalize_summary_row(row) do
    %{
      row
      | input_tokens: to_int(row.input_tokens),
        output_tokens: to_int(row.output_tokens),
        event_count: to_int(row.event_count)
    }
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
  defp to_int(nil), do: 0

  defp model_for(%TenantLlmSettings{} = s, :extraction),
    do: s.extraction_model || default_model(:extraction)

  defp model_for(%TenantLlmSettings{} = s, :classification),
    do: s.classification_model || default_model(:classification)

  defp model_for(%TenantLlmSettings{} = s, :merge),
    do: s.merge_model || default_model(:merge)

  defp model_for(%TenantLlmSettings{} = s, :embedding),
    do: s.embedding_model || default_model(:embedding)

  defp default_model(operation), do: Map.fetch!(@default_models, operation)

  defp has_key?(key), do: is_binary(key) and key != ""

  defp api_key_hint(key) when is_binary(key) do
    if String.length(key) >= 4, do: "..." <> String.slice(key, -4, 4), else: "..."
  end

  defp api_key_hint(_), do: nil

  # Accept both atom- and string-keyed attrs; whitelist to the known keys so an
  # attacker can't smuggle e.g. tenant_id in.
  @known_attr_keys ~w(api_key embedding_api_key extraction_model classification_model
                      merge_model embedding_model chat_provider chat_base_url
                      chat_api_key operation model provider input_tokens
                      output_tokens source_type article_id occurred_at)a
  defp normalize_keys(attrs) do
    Enum.reduce(@known_attr_keys, %{}, fn key, acc ->
      case fetch_attr(attrs, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, @max_summary_limit)
  defp clamp_limit(_), do: @default_summary_limit

  defp max_zero(n) when is_integer(n) and n > 0, do: n
  defp max_zero(_), do: 0

  # Audit the config change WITHOUT any key value. Always record `llm_config.updated`
  # with the changed model fields; additionally record `llm_config.key_set` /
  # `llm_config.embedding_key_set` when the respective key was set/rotated (value
  # never included — only its last-4 hint).
  defp audit_multi(tenant_id, settings, changeset, keys_set) do
    changed_models =
      changeset.changes
      |> Map.take([:extraction_model, :classification_model, :merge_model, :embedding_model])
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    # US-41.3: the chat ENDPOINT change is auditable (the url is not a secret and
    # naming it is the point — an operator must be able to see where tenant content
    # started going), while the credential remains value-free everywhere.
    changed_endpoint =
      changeset.changes
      |> Map.take([:chat_provider, :chat_base_url])
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    Multi.new()
    |> Audit.log_in_multi(:audit_updated, fn _ ->
      %{
        tenant_id: tenant_id,
        entity_type: "llm_config",
        entity_id: settings.id,
        action: "llm_config.updated",
        actor_type: "system",
        actor_id: nil,
        actor_label: "llm_config",
        new_state: %{
          "changed_models" => changed_models,
          "changed_chat_endpoint" => changed_endpoint,
          "api_key_set" => keys_set.api_key,
          "embedding_api_key_set" => keys_set.embedding_api_key,
          "chat_api_key_set" => keys_set.chat_api_key
        }
      }
    end)
    |> maybe_audit_key_set(tenant_id, settings, keys_set.api_key, :api_key)
    |> maybe_audit_key_set(tenant_id, settings, keys_set.embedding_api_key, :embedding_api_key)
    |> maybe_audit_key_set(tenant_id, settings, keys_set.chat_api_key, :chat_api_key)
  end

  defp maybe_audit_key_set(multi, _tenant_id, _settings, false, _field), do: multi

  defp maybe_audit_key_set(multi, tenant_id, settings, true, field) do
    {step, action, hint_key, value} =
      case field do
        :api_key ->
          {:audit_key_set, "llm_config.key_set", "api_key_hint", settings.api_key}

        :embedding_api_key ->
          {:audit_embedding_key_set, "llm_config.embedding_key_set", "embedding_api_key_hint",
           settings.embedding_api_key}

        :chat_api_key ->
          {:audit_chat_key_set, "llm_config.chat_key_set", "chat_api_key_hint",
           settings.chat_api_key}
      end

    Audit.log_in_multi(multi, step, fn _ ->
      %{
        tenant_id: tenant_id,
        entity_type: "llm_config",
        entity_id: settings.id,
        action: action,
        actor_type: "system",
        actor_id: nil,
        actor_label: "llm_config",
        # NEVER the key value — only that a key was set + its last-4 hint.
        new_state: %{hint_key => api_key_hint(value)}
      }
    end)
  end
end
