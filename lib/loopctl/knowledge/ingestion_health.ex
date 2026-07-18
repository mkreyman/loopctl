defmodule Loopctl.Knowledge.IngestionHealth do
  @moduledoc """
  Capture-silence detection + query context for `ingestion_anomalies`.

  A **dead-man's-switch** for knowledge ingestion. loopctl already detects the
  *presence of errors* (`Loopctl.TokenUsage.CostAnomaly`, `Loopctl.Telemetry.ScaleAlerts`)
  but had no detector for the *absence of expected success* — the failure mode
  where session-knowledge capture silently stopped (articles rejected/dropped)
  and nothing noticed the missing writes for months.

  `detect/1` scans every active tenant and each monitored article `source_type`.
  For a source_type that is **established** (has produced at least
  `established_threshold` articles) but whose most recent article is older than
  `staleness_threshold_hours`, it emits a `:capture_silence` candidate. A tenant
  that never produced captures of a source_type is never flagged (it was never
  established), so this fires only on genuine *went-silent* regressions.

  The persistence + notification (audit / operator alert / per-tenant webhook) of a
  candidate lives in `Loopctl.Workers.IngestionHealthWorker`, mirroring how
  `Loopctl.Workers.CostAnomalyWorker` owns anomaly creation. This module owns the
  detection query and the `list_anomalies/2` / `resolve_anomaly/3` read+resolve
  surface the API exposes.

  ## Config-based DI

  The three tunables resolve from `Application.get_env(:loopctl, :ingestion_health, [])`
  with in-code defaults (never opts, never `Application.put_env` in tests):

  - `:monitored_source_types` -- default `["session_log"]`
  - `:established_threshold` -- default `5`
  - `:staleness_threshold_hours` -- default `72`
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.Tenants.Tenant

  @default_monitored_source_types ["session_log"]
  @default_established_threshold 5
  @default_staleness_threshold_hours 72

  @type candidate :: %{
          tenant_id: Ecto.UUID.t(),
          source_type: String.t(),
          last_event_at: DateTime.t(),
          hours_stale: non_neg_integer(),
          sample_count: non_neg_integer()
        }

  # --- Config accessors (documented defaults) ---

  @doc "Article `source_type`s monitored for capture silence (default `[\"session_log\"]`)."
  @spec monitored_source_types() :: [String.t()]
  def monitored_source_types,
    do: Keyword.get(config(), :monitored_source_types, @default_monitored_source_types)

  @doc "Minimum article count for a source_type to count as ESTABLISHED (default 5)."
  @spec established_threshold() :: pos_integer()
  def established_threshold,
    do: Keyword.get(config(), :established_threshold, @default_established_threshold)

  @doc "Hours since the last article beyond which an established source_type is stale (default 72)."
  @spec staleness_threshold_hours() :: pos_integer()
  def staleness_threshold_hours,
    do: Keyword.get(config(), :staleness_threshold_hours, @default_staleness_threshold_hours)

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
      staleness_threshold_hours: staleness_threshold_hours()
    })
  end

  @doc """
  `detect/0` with explicit config (`:monitored_source_types`, `:established_threshold`,
  `:staleness_threshold_hours`). Exposed so a caller can drive detection with a
  specific configuration without touching global app env.
  """
  @spec detect(%{
          monitored_source_types: [String.t()],
          established_threshold: pos_integer(),
          staleness_threshold_hours: pos_integer()
        }) :: [candidate()]
  def detect(%{
        monitored_source_types: source_types,
        established_threshold: established,
        staleness_threshold_hours: staleness_hours
      }) do
    now = DateTime.utc_now()

    active_tenant_ids()
    |> Enum.flat_map(&detect_for_tenant(&1, source_types, established, staleness_hours, now))
  end

  # Groups the tenant's monitored-source_type articles by source_type in ONE query,
  # yielding sample_count + last_event_at, then keeps only the established+stale ones.
  # A source_type with zero articles never appears in the grouped result, so it is
  # correctly never flagged (not established).
  defp detect_for_tenant(tenant_id, source_types, established, staleness_hours, now) do
    Article
    |> where([a], a.tenant_id == ^tenant_id)
    |> where([a], a.source_type in ^source_types)
    |> group_by([a], a.source_type)
    |> select([a], %{
      source_type: a.source_type,
      sample_count: count(a.id),
      last_event_at: max(a.inserted_at)
    })
    |> AdminRepo.all()
    |> Enum.flat_map(fn %{source_type: st, sample_count: count, last_event_at: last} ->
      candidate_or_skip(tenant_id, st, count, last, established, staleness_hours, now)
    end)
  end

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
      changeset = IngestionAnomaly.resolve_changeset(anomaly)

      multi =
        Multi.new()
        |> Multi.update(:anomaly, changeset)
        |> Audit.log_in_multi(:audit, fn %{anomaly: resolved} ->
          %{
            tenant_id: tenant_id,
            entity_type: "ingestion_anomaly",
            entity_id: resolved.id,
            action: "resolved",
            actor_type: Keyword.get(opts, :actor_type, "api_key"),
            actor_id: Keyword.get(opts, :actor_id),
            actor_label: Keyword.get(opts, :actor_label),
            old_state: %{"resolved" => false},
            new_state: %{"resolved" => true}
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{anomaly: anomaly}} -> {:ok, anomaly}
        {:error, :anomaly, changeset, _} -> {:error, changeset}
        {:error, _step, error, _} -> {:error, error}
      end
    end
  end

  # --- Private helpers ---

  defp active_tenant_ids do
    Tenant
    |> where([t], t.status == :active)
    |> select([t], t.id)
    |> AdminRepo.all()
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
