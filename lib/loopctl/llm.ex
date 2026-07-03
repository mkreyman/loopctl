defmodule Loopctl.Llm do
  @moduledoc """
  Per-tenant BYO Anthropic LLM configuration + usage tracking (Epic 28 residual, #179).

  loopctl is multi-tenant and **BYO-key**: every tenant supplies its OWN Anthropic
  API key and pays Anthropic directly. loopctl fronts no LLM cost — there is no
  markup, price table, or billing. A tenant with no configured key CANNOT run
  tenant knowledge-LLM work (ingest/classify/merge): `resolve/2` returns
  `{:error, :no_api_key}` and callers fail cleanly (a 422 at the API boundary; the
  Oban worker `{:discard}`s). There is intentionally NO global-system-key fallback
  for tenant LLM work.

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
  alias Loopctl.Llm.TenantLlmSettings
  alias Loopctl.Llm.UsageEvent

  # Server default model per operation when the tenant left that field nil. A key
  # is still MANDATORY — the default only fills the model, never the key. Haiku is
  # the cheap sensible default; a tenant overrides per-operation as they wish.
  @default_model "claude-haiku-4-5-20251001"
  @default_models %{
    extraction: @default_model,
    classification: @default_model,
    merge: @default_model
  }

  @type operation :: :extraction | :classification | :merge
  @type resolved :: %{api_key: String.t(), model: String.t()}

  # --- Settings ---

  @doc """
  Returns the tenant's LLM settings row, or `nil` if none exists.

  The `api_key` field on the returned struct is decrypted plaintext — treat it as
  a secret. Prefer `resolve/2` for LLM call sites.
  """
  @spec get_settings(Ecto.UUID.t()) :: TenantLlmSettings.t() | nil
  def get_settings(tenant_id) when is_binary(tenant_id) do
    AdminRepo.get_by(TenantLlmSettings, tenant_id: tenant_id)
  end

  @doc """
  Upserts the tenant's LLM settings (one row per tenant).

  `attrs` may carry any of `api_key`, `extraction_model`, `classification_model`,
  `merge_model` (string or atom keys). `tenant_id` is set programmatically. The
  api_key (when present) is stored encrypted and NEVER cast from params. When an
  api_key is set/rotated, an `llm_config.key_set` audit event is written WITHOUT
  the value; every upsert writes an `llm_config.updated` event listing which
  model fields changed.

  Returns `{:ok, settings}` or `{:error, changeset}`.
  """
  @spec upsert_settings(Ecto.UUID.t(), map()) ::
          {:ok, TenantLlmSettings.t()} | {:error, Ecto.Changeset.t()}
  def upsert_settings(tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs) do
    attrs = normalize_keys(attrs)
    api_key = Map.get(attrs, :api_key)
    existing = get_settings(tenant_id)

    changeset =
      (existing || %TenantLlmSettings{tenant_id: tenant_id})
      |> TenantLlmSettings.models_changeset(attrs)
      |> TenantLlmSettings.put_api_key(api_key)
      |> Ecto.Changeset.put_change(:tenant_id, tenant_id)

    key_set? = not is_nil(api_key)

    Multi.new()
    |> Multi.insert_or_update(:settings, changeset)
    |> Multi.merge(fn %{settings: settings} ->
      audit_multi(tenant_id, settings, changeset, key_set?)
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{settings: settings}} -> {:ok, settings}
      {:error, :settings, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Resolves the tenant's API key + per-operation model for an LLM call.

  Returns `{:ok, %{api_key: decrypted, model: model}}` or `{:error, :no_api_key}`
  when the tenant has no key configured (mandatory BYO — no fallback). When the
  tenant left the per-operation model nil, the server default for that operation
  is used.
  """
  @spec resolve(Ecto.UUID.t(), operation()) :: {:ok, resolved()} | {:error, :no_api_key}
  def resolve(tenant_id, operation)
      when is_binary(tenant_id) and operation in [:extraction, :classification, :merge] do
    case get_settings(tenant_id) do
      %TenantLlmSettings{api_key: key} = settings when is_binary(key) and key != "" ->
        {:ok, %{api_key: key, model: model_for(settings, operation)}}

      _ ->
        {:error, :no_api_key}
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
  Records that a tenant LLM `operation` was BLOCKED for a missing BYO key
  (review #2 — the mandatory-BYO cutover needs observability). Emits a
  `Logger.warning`, a `[:loopctl, :llm, :blocked]` telemetry event, and an
  `llm.blocked_no_api_key` audit entry (with tenant_id + operation, never a key).
  Best-effort: a telemetry/audit failure never propagates to the caller.
  """
  @spec record_blocked(Ecto.UUID.t(), operation()) :: :ok
  def record_blocked(tenant_id, operation) when is_binary(tenant_id) do
    Logger.warning(
      "Loopctl.Llm: tenant=#{tenant_id} blocked op=#{operation} — no Anthropic API key " <>
        "configured (mandatory BYO)."
    )

    :telemetry.execute([:loopctl, :llm, :blocked], %{count: 1}, %{
      tenant_id: tenant_id,
      operation: operation
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
  A safe view of the tenant's settings for API responses: the model choices,
  `has_api_key`, and a `api_key_hint` (last 4 chars) — NEVER the key itself.
  """
  @spec settings_view(TenantLlmSettings.t() | nil) :: map()
  def settings_view(nil) do
    %{
      has_api_key: false,
      api_key_hint: nil,
      extraction_model: nil,
      classification_model: nil,
      merge_model: nil
    }
  end

  def settings_view(%TenantLlmSettings{} = s) do
    %{
      has_api_key: has_key?(s.api_key),
      api_key_hint: api_key_hint(s.api_key),
      extraction_model: s.extraction_model,
      classification_model: s.classification_model,
      merge_model: s.merge_model
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
  Aggregates a tenant's usage, grouped by operation + model + source_type + day,
  summing input/output tokens and counting events, over an optional date range.

  Opts: `:from`, `:to` (DateTime), `:limit` (default #{@default_summary_limit},
  clamped to #{@max_summary_limit}), `:offset` (default 0). Rows are ordered
  `day desc` with an `(operation, model, source_type)` tiebreaker for a stable
  page across equal days.

  Returns `%{data: [row], meta: %{limit, offset, total_count}}` where each row is
  `%{day, operation, model, source_type, input_tokens, output_tokens, event_count}`.
  """
  @spec usage_summary(Ecto.UUID.t(), keyword()) :: %{data: [map()], meta: map()}
  def usage_summary(tenant_id, opts \\ []) when is_binary(tenant_id) do
    limit = opts |> Keyword.get(:limit, @default_summary_limit) |> clamp_limit()
    offset = opts |> Keyword.get(:offset, 0) |> max_zero()

    base = usage_base_query(tenant_id, opts)

    grouped =
      from(e in base,
        group_by: [
          fragment("date_trunc('day', ?)", e.occurred_at),
          e.operation,
          e.model,
          e.source_type
        ],
        select: %{
          day: fragment("date_trunc('day', ?)", e.occurred_at),
          operation: e.operation,
          model: e.model,
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

    %{data: rows, meta: %{limit: limit, offset: offset, total_count: total}}
  end

  # --- Private ---

  # Default the lower bound to a 90-day lookback when the caller omits `:from`, so
  # the aggregate can never unboundedly scan the whole table (review #9). An
  # explicit `:from`/`:to` is honored (the (tenant_id, occurred_at) index keeps a
  # bounded range efficient).
  @default_lookback_days 90

  defp usage_base_query(tenant_id, opts) do
    from(e in UsageEvent, where: e.tenant_id == ^tenant_id)
    |> maybe_from(Keyword.get(opts, :from) || default_from())
    |> maybe_to(Keyword.get(opts, :to))
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

  defp default_model(operation), do: Map.fetch!(@default_models, operation)

  defp has_key?(key), do: is_binary(key) and key != ""

  defp api_key_hint(key) when is_binary(key) do
    if String.length(key) >= 4, do: "..." <> String.slice(key, -4, 4), else: "..."
  end

  defp api_key_hint(_), do: nil

  # Accept both atom- and string-keyed attrs; whitelist to the known keys so an
  # attacker can't smuggle e.g. tenant_id in.
  @known_attr_keys ~w(api_key extraction_model classification_model merge_model
                      operation model input_tokens output_tokens source_type
                      article_id occurred_at)a
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

  # Audit the config change WITHOUT the key value. Always record `llm_config.updated`
  # with the changed model fields; additionally record `llm_config.key_set` when the
  # api_key was set/rotated (value never included).
  defp audit_multi(tenant_id, settings, changeset, key_set?) do
    changed_models =
      changeset.changes
      |> Map.take([:extraction_model, :classification_model, :merge_model])
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    multi =
      Audit.log_in_multi(Multi.new(), :audit_updated, fn _ ->
        %{
          tenant_id: tenant_id,
          entity_type: "llm_config",
          entity_id: settings.id,
          action: "llm_config.updated",
          actor_type: "system",
          actor_id: nil,
          actor_label: "llm_config",
          new_state: %{"changed_models" => changed_models, "api_key_set" => key_set?}
        }
      end)

    if key_set? do
      Audit.log_in_multi(multi, :audit_key_set, fn _ ->
        %{
          tenant_id: tenant_id,
          entity_type: "llm_config",
          entity_id: settings.id,
          action: "llm_config.key_set",
          actor_type: "system",
          actor_id: nil,
          actor_label: "llm_config",
          # NEVER the key value — only that a key was set + its last-4 hint.
          new_state: %{"api_key_hint" => api_key_hint(settings.api_key)}
        }
      end)
    else
      multi
    end
  end
end
