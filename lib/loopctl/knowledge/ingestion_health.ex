defmodule Loopctl.Knowledge.IngestionHealth do
  @moduledoc """
  Capture-silence detection + query context for `ingestion_anomalies`.

  A **dead-man's-switch** for knowledge ingestion. loopctl already detects the
  *presence of errors* (`Loopctl.TokenUsage.CostAnomaly`, `Loopctl.Telemetry.ScaleAlerts`)
  but had no detector for the *absence of expected success* — the failure mode
  where session-knowledge capture silently stopped (articles rejected/dropped)
  and nothing noticed the missing writes for months.

  `detect/1` scans every active tenant and each monitored article `source_type`
  in ONE grouped query (joined against active tenants — no per-tenant fan-out).
  For a source_type that is **recently established** (has produced at least
  `established_threshold` articles WITHIN `establishment_window_hours`) but whose
  most recent article is older than `staleness_threshold_hours`, it emits a
  `:capture_silence` candidate. A tenant that never produced captures of a
  source_type is never flagged (it was never established), so this fires only on
  genuine *went-silent* regressions.

  ## Recency window (no perpetual false positives)

  Establishment is scoped to a rolling `establishment_window_hours` window, not an
  all-time count. A source_type that produced captures long ago and then
  legitimately wound down (project completed, workflow retired) drops out of the
  window once its last capture ages past it, so it stops being flagged instead of
  being reported as stale forever. Genuine regressions (recently active, now
  silent) still fire because their captures are inside the window. For a
  source_type an operator KNOWS is retired, archiving its anomaly permanently
  suppresses re-detection (see `Loopctl.Workers.IngestionHealthWorker`).

  The persistence + notification (audit / operator alert / per-tenant webhook) of a
  candidate lives in `Loopctl.Workers.IngestionHealthWorker`, mirroring how
  `Loopctl.Workers.CostAnomalyWorker` owns anomaly creation. This module owns the
  detection query and the `list_anomalies/2` / `resolve_anomaly/3` read+resolve
  surface the API exposes.

  ## Config-based DI

  The tunables resolve from `Application.get_env(:loopctl, :ingestion_health, [])`
  with in-code defaults (never opts, never `Application.put_env` in tests):

  - `:monitored_source_types` -- default `:all` (every source_type that crosses the
    established threshold; a list narrows monitoring to specific source_types)
  - `:established_threshold` -- default `5`
  - `:staleness_threshold_hours` -- default `72`
  - `:establishment_window_hours` -- default `720` (30 days)
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.Tenants.Tenant

  @default_monitored_source_types :all
  @default_established_threshold 5
  @default_staleness_threshold_hours 72
  @default_establishment_window_hours 720

  @type candidate :: %{
          tenant_id: Ecto.UUID.t(),
          source_type: String.t(),
          last_event_at: DateTime.t(),
          hours_stale: non_neg_integer(),
          sample_count: non_neg_integer()
        }

  # --- Config accessors (documented defaults) ---

  @doc """
  Article `source_type`s monitored for capture silence.

  `:all` (the default) monitors every source_type that crosses the established
  threshold; a list narrows monitoring to specific source_types.
  """
  @spec monitored_source_types() :: :all | [String.t()]
  def monitored_source_types,
    do: Keyword.get(config(), :monitored_source_types, @default_monitored_source_types)

  @doc "Minimum article count (within the establishment window) for a source_type to count as ESTABLISHED (default 5)."
  @spec established_threshold() :: pos_integer()
  def established_threshold,
    do: Keyword.get(config(), :established_threshold, @default_established_threshold)

  @doc "Hours since the last article beyond which an established source_type is stale (default 72)."
  @spec staleness_threshold_hours() :: pos_integer()
  def staleness_threshold_hours,
    do: Keyword.get(config(), :staleness_threshold_hours, @default_staleness_threshold_hours)

  @doc """
  Rolling window (in hours) within which a source_type's captures must fall to
  count toward establishment (default 720 = 30 days). Scopes establishment to
  RECENT activity so a wound-down source_type is not perpetually flagged.
  """
  @spec establishment_window_hours() :: pos_integer()
  def establishment_window_hours,
    do: Keyword.get(config(), :establishment_window_hours, @default_establishment_window_hours)

  defp config, do: Application.get_env(:loopctl, :ingestion_health, [])

  # --- Detection ---

  @doc """
  Scans every active tenant for capture-silence candidates using the configured
  tunables. Returns a flat list of `t:candidate/0` maps — PURE, no DB writes.

  The worker turns each candidate into a persisted anomaly (race-safe) and notifies.
  """
  @spec detect() :: [candidate()]
  def detect do
    detect(%{
      monitored_source_types: monitored_source_types(),
      established_threshold: established_threshold(),
      staleness_threshold_hours: staleness_threshold_hours(),
      establishment_window_hours: establishment_window_hours()
    })
  end

  @doc """
  `detect/0` with explicit config (`:monitored_source_types`, `:established_threshold`,
  `:staleness_threshold_hours`, optional `:establishment_window_hours`). Exposed so a
  caller can drive detection with a specific configuration without touching global
  app env.
  """
  @spec detect(%{
          required(:monitored_source_types) => :all | [String.t()],
          required(:established_threshold) => pos_integer(),
          required(:staleness_threshold_hours) => pos_integer(),
          optional(:establishment_window_hours) => pos_integer()
        }) :: [candidate()]
  def detect(
        %{
          monitored_source_types: source_types,
          established_threshold: established,
          staleness_threshold_hours: staleness_hours
        } = opts
      ) do
    now = DateTime.utc_now()
    window_hours = Map.get(opts, :establishment_window_hours, establishment_window_hours())
    window_start = DateTime.add(now, -window_hours * 3600, :second)

    # ONE grouped query across ALL active tenants (no per-tenant fan-out): the
    # join to active tenants + group_by (tenant_id, source_type) yields
    # sample_count + last_event_at per (tenant, source_type). Establishment is
    # scoped to the recency window (inserted_at >= window_start) so wound-down
    # source_types age out instead of being flagged forever. A source_type with
    # no recent articles never appears in the result (not recently established).
    Article
    |> join(:inner, [a], t in Tenant, on: t.id == a.tenant_id and t.status == :active)
    |> where([a], not is_nil(a.source_type))
    |> where([a], a.inserted_at >= ^window_start)
    |> filter_source_types(source_types)
    |> group_by([a], [a.tenant_id, a.source_type])
    |> select([a], %{
      tenant_id: a.tenant_id,
      source_type: a.source_type,
      sample_count: count(a.id),
      last_event_at: max(a.inserted_at)
    })
    |> AdminRepo.all()
    |> Enum.flat_map(fn %{
                          tenant_id: tid,
                          source_type: st,
                          sample_count: count,
                          last_event_at: last
                        } ->
      candidate_or_skip(tid, st, count, last, established, staleness_hours, now)
    end)
  end

  # `:all` monitors every source_type; a list narrows to the given source_types.
  defp filter_source_types(query, :all), do: query

  defp filter_source_types(query, source_types) when is_list(source_types),
    do: where(query, [a], a.source_type in ^source_types)

  defp candidate_or_skip(
         tenant_id,
         source_type,
         sample_count,
         last_event_at,
         established,
         staleness_hours,
         now
       ) do
    hours_stale = hours_between(last_event_at, now)

    if sample_count >= established and is_integer(hours_stale) and hours_stale > staleness_hours do
      [
        %{
          tenant_id: tenant_id,
          source_type: source_type,
          last_event_at: to_utc_datetime(last_event_at),
          hours_stale: hours_stale,
          sample_count: sample_count
        }
      ]
    else
      []
    end
  end

  # --- Query surface (mirrors Loopctl.TokenUsage.list_anomalies/resolve_anomaly) ---

  @doc """
  Lists capture-silence anomalies for a tenant.

  ## Options (keyword list)

  - `:source_type` -- filter by source_type
  - `:anomaly_type` -- filter by anomaly type (`:capture_silence`)
  - `:resolved` -- filter by resolved status (default `false`)
  - `:include_archived` -- when `true`, include archived anomalies (default `false`)
  - `:page` -- page number (default 1)
  - `:page_size` -- entries per page (default 20, max 100)

  ## Returns

  `{:ok, %{data: [IngestionAnomaly.t()], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_anomalies(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [IngestionAnomaly.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_anomalies(tenant_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size
    resolved = Keyword.get(opts, :resolved, false)
    include_archived = Keyword.get(opts, :include_archived, false)

    base_query =
      IngestionAnomaly
      |> where([a], a.tenant_id == ^tenant_id)
      |> where([a], a.resolved == ^resolved)
      |> apply_archive_filter(include_archived)
      |> apply_filter(:source_type, Keyword.get(opts, :source_type))
      |> apply_filter(:anomaly_type, Keyword.get(opts, :anomaly_type))

    total = AdminRepo.aggregate(base_query, :count, :id)

    data =
      base_query
      |> order_by([a], desc: a.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Gets a single ingestion anomaly by ID, scoped to a tenant.

  Returns `{:ok, %IngestionAnomaly{}}` or `{:error, :not_found}`.
  """
  @spec get_anomaly(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, IngestionAnomaly.t()} | {:error, :not_found}
  def get_anomaly(tenant_id, anomaly_id) do
    case AdminRepo.get_by(IngestionAnomaly, id: anomaly_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      anomaly -> {:ok, anomaly}
    end
  end

  @doc """
  Marks an ingestion anomaly as resolved, writing an audit entry in the same transaction.

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  Returns `{:ok, %IngestionAnomaly{}}` or `{:error, :not_found}` / `{:error, changeset}`.
  """
  @spec resolve_anomaly(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, IngestionAnomaly.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def resolve_anomaly(tenant_id, anomaly_id, opts \\ []) do
    with {:ok, anomaly} <- get_anomaly(tenant_id, anomaly_id) do
      # Idempotent + audit-honest: re-resolving an already-resolved anomaly is a
      # no-op that returns it as-is, so we never write a bogus `false -> true`
      # audit transition for a row that was already resolved.
      if anomaly.resolved,
        do: {:ok, anomaly},
        else: do_resolve(tenant_id, anomaly, opts)
    end
  end

  defp do_resolve(tenant_id, anomaly, opts) do
    Multi.new()
    |> Multi.update(:anomaly, IngestionAnomaly.resolve_changeset(anomaly))
    |> Audit.log_in_multi(:audit, fn %{anomaly: resolved} ->
      audit_attrs(tenant_id, resolved.id, "resolved", opts, %{
        # Derive old_state from the actual prior value (guaranteed false here).
        old_state: %{"resolved" => anomaly.resolved},
        new_state: %{"resolved" => true}
      })
    end)
    |> run_anomaly_multi()
  end

  @doc """
  Archives an ingestion anomaly, writing an audit entry in the same transaction.

  Archiving is the operator's PERMANENT escape hatch for a legitimately-retired
  `source_type`: an archived anomaly is hidden from the default list AND suppresses
  re-detection for that source_type in `Loopctl.Workers.IngestionHealthWorker`, so a
  wound-down workflow is not re-flagged on every hourly run.

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  Returns `{:ok, %IngestionAnomaly{}}` or `{:error, :not_found}` / `{:error, changeset}`.
  Re-archiving an already-archived anomaly is an idempotent no-op.
  """
  @spec archive_anomaly(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, IngestionAnomaly.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def archive_anomaly(tenant_id, anomaly_id, opts \\ []) do
    with {:ok, anomaly} <- get_anomaly(tenant_id, anomaly_id) do
      if anomaly.archived,
        do: {:ok, anomaly},
        else: do_archive(tenant_id, anomaly, opts)
    end
  end

  defp do_archive(tenant_id, anomaly, opts) do
    Multi.new()
    |> Multi.update(:anomaly, IngestionAnomaly.archive_changeset(anomaly))
    |> Audit.log_in_multi(:audit, fn %{anomaly: archived} ->
      audit_attrs(tenant_id, archived.id, "archived", opts, %{
        old_state: %{"archived" => anomaly.archived},
        new_state: %{"archived" => true}
      })
    end)
    |> run_anomaly_multi()
  end

  # --- Private helpers ---

  defp audit_attrs(tenant_id, entity_id, action, opts, states) do
    Map.merge(
      %{
        tenant_id: tenant_id,
        entity_type: "ingestion_anomaly",
        entity_id: entity_id,
        action: action,
        actor_type: Keyword.get(opts, :actor_type, "api_key"),
        actor_id: Keyword.get(opts, :actor_id),
        actor_label: Keyword.get(opts, :actor_label)
      },
      states
    )
  end

  defp run_anomaly_multi(multi) do
    case AdminRepo.transaction(multi) do
      {:ok, %{anomaly: anomaly}} -> {:ok, anomaly}
      {:error, :anomaly, changeset, _} -> {:error, changeset}
      {:error, _step, error, _} -> {:error, error}
    end
  end

  # Exclude archived anomalies by default; include them when requested.
  defp apply_archive_filter(query, true), do: query
  defp apply_archive_filter(query, _), do: where(query, [a], a.archived == false)

  defp apply_filter(query, _field, nil), do: query
  defp apply_filter(query, _field, ""), do: query

  defp apply_filter(query, :source_type, value) when is_binary(value),
    do: where(query, [a], a.source_type == ^value)

  defp apply_filter(query, :anomaly_type, value) when is_binary(value) do
    known = Enum.map(IngestionAnomaly.anomaly_types(), &Atom.to_string/1)

    if value in known do
      atom_val = String.to_existing_atom(value)
      where(query, [a], a.anomaly_type == ^atom_val)
    else
      where(query, [_a], false)
    end
  end

  defp apply_filter(query, :anomaly_type, value) when is_atom(value),
    do: where(query, [a], a.anomaly_type == ^value)

  # Whole hours between an aggregate max(inserted_at) and now. `max/1` over a
  # :utc_datetime_usec column can come back as a NaiveDateTime, so normalize both.
  defp hours_between(nil, _now), do: nil

  defp hours_between(last, now) do
    div(DateTime.diff(now, to_utc_datetime(last), :second), 3600)
  end

  defp to_utc_datetime(%DateTime{} = dt), do: dt
  defp to_utc_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
end
