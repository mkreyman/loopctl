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

  ## Index / scan cost

  The grouped scan filters `articles.inserted_at >= window_start`; the supporting
  index (`articles_inserted_tenant_source_idx`) LEADS with `inserted_at` so that
  predicate is an index RANGE SEEK — the read is bounded to the rolling window
  (recent activity), NOT the whole corpus, so cost does not grow unbounded as the
  article table ages.

  ## Monitoring contract: source_type must be stamped

  detect/1 only sees articles with a NON-NULL `source_type` (`where not is_nil`).
  `source_type` is an advisory, nullable field on `Loopctl.Knowledge.Article`, so
  a write path that omits it produces articles this monitor CANNOT see — a silent
  outage on such a path would go undetected. Any ingestion path you want covered
  by the dead-man's-switch (session capture, batch ingest, content ingestion)
  MUST stamp a known `source_type` (see `Article.known_source_types/0`). Whether a
  given upstream writer is required to stamp one is a product/contract decision;
  this module's guarantee is scoped to paths that do.

  ## Recency window (no perpetual false positives)

  Establishment is scoped to a rolling `establishment_window_hours` window, not an
  all-time count. A source_type that produced captures long ago and then
  legitimately wound down (project completed, workflow retired) drops out of the
  window once its last capture ages past it, so it stops being flagged instead of
  being reported as stale forever. Genuine regressions (recently active, now
  silent) still fire because their captures are inside the window. For a
  source_type an operator KNOWS is retired, archiving its anomaly suppresses
  re-detection (see `Loopctl.Workers.IngestionHealthWorker`); archiving is
  REVERSIBLE via `unarchive_anomaly/3` so a mistaken suppression can be lifted.

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
  - `:established_threshold_overrides` -- default `%{}` (per-source-type establishment
    thresholds, e.g. `%{"session_log" => 2}` to monitor a low-volume critical source)
  - `:staleness_threshold_hours` -- default `72`
  - `:establishment_window_hours` -- default `720` (30 days)
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.Tenants.Tenant

  @default_monitored_source_types :all
  @default_established_threshold 5
  @default_staleness_threshold_hours 72
  @default_establishment_window_hours 720
  @default_established_threshold_overrides %{}

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

  @doc """
  Per-source-type overrides for the establishment threshold.

  A map of `source_type => pos_integer`. A low-volume but critical source_type
  (e.g. 3-4 captures/month) would never cross the global `established_threshold`
  and so would never be monitored; an override lets an operator lower the bar for
  that specific source_type without weakening the default for noisy ones. Default
  `%{}` (no overrides — every source_type uses the global threshold).
  """
  @spec established_threshold_overrides() :: %{optional(String.t()) => pos_integer()}
  def established_threshold_overrides,
    do:
      Keyword.get(
        config(),
        :established_threshold_overrides,
        @default_established_threshold_overrides
      )

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
      established_threshold_overrides: established_threshold_overrides(),
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
          optional(:established_threshold_overrides) => %{optional(String.t()) => pos_integer()},
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
    overrides = Map.get(opts, :established_threshold_overrides, %{})

    # ONE grouped query across ALL active tenants (no per-tenant fan-out): the
    # join to active tenants + group_by (tenant_id, source_type) yields
    # sample_count + last_event_at per (tenant, source_type). Establishment is
    # scoped to the recency window (inserted_at >= window_start) so wound-down
    # source_types age out instead of being flagged forever, AND so the read is
    # bounded to the window via the inserted_at-leading index (articles_inserted_
    # tenant_source_idx) rather than scanning the whole corpus. A source_type with
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
      threshold = Map.get(overrides, st, established)
      candidate_or_skip(tid, st, count, last, threshold, staleness_hours, now)
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
  - `:resolved` -- filter by resolved status: `false` (default, unresolved only),
    `true` (resolved only), or `:all` (both — the complete timeline in one call)
  - `:include_archived` -- when `true`, include archived anomalies (default `false`)
  - `:page` -- page number (default 1)
  - `:page_size` -- entries per page (default 20, max 100)

  For UNRESOLVED rows, `hours_stale` is recomputed at read time from
  `last_event_at` to now, so a long-running outage reports its TRUE current age
  rather than the frozen detection-time snapshot. Resolved rows keep their
  historical (detection-time) figures.

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
      |> apply_resolved_filter(resolved)
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
      |> Enum.map(&refresh_staleness(&1, DateTime.utc_now()))

    {:ok, %{data: data, total: total, page: page, page_size: page_size}}
  end

  # `resolved: :all` returns both resolved and unresolved (the complete timeline);
  # a boolean narrows to that status. Default (false) is unresolved-only.
  defp apply_resolved_filter(query, :all), do: query
  defp apply_resolved_filter(query, resolved), do: where(query, [a], a.resolved == ^resolved)

  # Recompute hours_stale for an UNRESOLVED anomaly from its last_event_at to now,
  # so a long outage reports its true current age instead of the frozen
  # detection-time snapshot. Resolved rows keep their historical figures.
  defp refresh_staleness(%IngestionAnomaly{resolved: false, last_event_at: last} = anomaly, now)
       when not is_nil(last) do
    case hours_between(last, now) do
      hours when is_integer(hours) and hours > anomaly.hours_stale ->
        %{anomaly | hours_stale: hours}

      _ ->
        anomaly
    end
  end

  defp refresh_staleness(anomaly, _now), do: anomaly

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
    transition(
      tenant_id,
      anomaly,
      opts,
      :resolved,
      false,
      true,
      "resolved",
      &IngestionAnomaly.resolve_changeset/1
    )
  end

  @doc """
  Archives an ingestion anomaly, writing an audit entry in the same transaction.

  Archiving is the operator's escape hatch for a legitimately-retired
  `source_type`: an archived anomaly is hidden from the default list AND suppresses
  re-detection for that source_type in `Loopctl.Workers.IngestionHealthWorker`, so a
  wound-down workflow is not re-flagged on every hourly run. It is REVERSIBLE via
  `unarchive_anomaly/3` — a mistaken archive (e.g. a workflow later revived) can be
  undone to restore monitoring, so the escape hatch is not a permanent blind spot.

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
    transition(
      tenant_id,
      anomaly,
      opts,
      :archived,
      false,
      true,
      "archived",
      &IngestionAnomaly.archive_changeset/1
    )
  end

  @doc """
  Un-archives an ingestion anomaly — the inverse of `archive_anomaly/3`.

  Restores monitoring for a source_type whose anomaly was archived: once
  un-archived, `Loopctl.Workers.IngestionHealthWorker` no longer suppresses
  re-detection, so a revived-then-silent workflow is caught again. This is what
  keeps archive from being an irreversible, permanent blind spot. Writes an
  audit entry in the same transaction. Un-archiving a non-archived anomaly is an
  idempotent no-op.

  ## Options (keyword list)

  - `:actor_id` -- audit actor ID
  - `:actor_label` -- audit actor label
  - `:actor_type` -- audit actor type (default "api_key")

  Returns `{:ok, %IngestionAnomaly{}}` or `{:error, :not_found}` / `{:error, changeset}`.
  """
  @spec unarchive_anomaly(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, IngestionAnomaly.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def unarchive_anomaly(tenant_id, anomaly_id, opts \\ []) do
    with {:ok, anomaly} <- get_anomaly(tenant_id, anomaly_id) do
      if anomaly.archived,
        do: do_unarchive(tenant_id, anomaly, opts),
        else: {:ok, anomaly}
    end
  end

  defp do_unarchive(tenant_id, anomaly, opts) do
    transition(
      tenant_id,
      anomaly,
      opts,
      :archived,
      true,
      false,
      "unarchived",
      &IngestionAnomaly.unarchive_changeset/1
    )
  end

  @doc """
  Auto-resolves open anomalies whose captures have RESUMED.

  Scans every unresolved, non-archived capture-silence anomaly and, when at least
  one article of that `(tenant, source_type)` has arrived AFTER the anomaly's
  `last_event_at`, resolves it (actor_type "system"). Without this an anomaly for
  a fully-recovered stream would stay open forever showing frozen figures, so an
  operator could not tell "recovered" from "still silent". Called by the hourly
  worker. Returns the number of anomalies auto-resolved.
  """
  @spec auto_resolve_recovered() :: non_neg_integer()
  def auto_resolve_recovered do
    open =
      IngestionAnomaly
      |> where([a], a.resolved == false and a.archived == false)
      |> where([a], a.anomaly_type == :capture_silence)
      |> AdminRepo.all()

    Enum.reduce(open, 0, fn anomaly, acc -> acc + resolve_if_recovered(anomaly) end)
  end

  # Returns 1 if the anomaly's captures resumed AND it was resolved, else 0.
  defp resolve_if_recovered(anomaly) do
    with true <- captures_resumed?(anomaly),
         {:ok, _} <-
           do_resolve(anomaly.tenant_id, anomaly,
             actor_type: "system",
             actor_label: "ingestion_health:auto_resolve"
           ) do
      1
    else
      _ -> 0
    end
  end

  defp captures_resumed?(%IngestionAnomaly{last_event_at: nil}), do: false

  defp captures_resumed?(%IngestionAnomaly{
         tenant_id: tenant_id,
         source_type: source_type,
         last_event_at: last
       }) do
    Article
    |> where(
      [a],
      a.tenant_id == ^tenant_id and a.source_type == ^source_type and a.inserted_at > ^last
    )
    |> AdminRepo.exists?()
  end

  # --- Private helpers ---

  # Locked, audit-honest boolean flip: re-reads the row FOR UPDATE inside the
  # transaction and only updates + audits when it is actually in the `from` state.
  # Two concurrent callers therefore serialize — the first transitions and audits,
  # the second observes the row already at `to` and is a no-op with NO bogus audit
  # entry (the append-only log never records a transition that did not happen).
  defp transition(tenant_id, anomaly, opts, field, from, to, action, changeset_fun) do
    Multi.new()
    |> Multi.run(:locked, fn repo, _changes ->
      locked =
        IngestionAnomaly
        |> where([a], a.id == ^anomaly.id and a.tenant_id == ^tenant_id)
        |> lock("FOR UPDATE")
        |> repo.one()

      {:ok, locked}
    end)
    |> Multi.run(:anomaly, fn repo, %{locked: locked} ->
      cond do
        is_nil(locked) -> {:error, :not_found}
        Map.fetch!(locked, field) == from -> repo.update(changeset_fun.(locked))
        true -> {:ok, locked}
      end
    end)
    |> Multi.run(:audit, fn repo, %{locked: locked, anomaly: updated} ->
      if not is_nil(locked) and Map.fetch!(locked, field) == from do
        audit_insert(
          repo,
          audit_attrs(tenant_id, updated.id, action, opts, %{
            old_state: %{Atom.to_string(field) => from},
            new_state: %{Atom.to_string(field) => to}
          })
        )
      else
        {:ok, :skipped}
      end
    end)
    |> run_anomaly_multi()
  end

  # Inserts an audit entry via the transaction's repo (keeps audit atomic with the
  # anomaly update), mirroring Loopctl.Audit.log_in_multi's changeset construction.
  defp audit_insert(repo, attrs) do
    {tenant_id, attrs} = Map.pop(attrs, :tenant_id)

    attrs
    |> AuditLog.create_changeset()
    |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
    |> repo.insert()
  end

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
