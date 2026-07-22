defmodule Loopctl.Knowledge.IngestionAnomaly do
  @moduledoc """
  Schema for the `ingestion_anomalies` table.

  A capture-silence anomaly is a **dead-man's-switch** for knowledge ingestion:
  it records that a tenant which HISTORICALLY produced captured articles of a
  given `source_type` (e.g. `"session_log"`) has gone silent — no new article of
  that source_type has been written for longer than the staleness threshold.

  This is the sibling detector-class to `Loopctl.TokenUsage.CostAnomaly`. Where
  CostAnomaly (and ScaleAlerts) detect the *presence of errors*, this detects the
  *absence of expected success* — the failure mode where session-knowledge capture
  silently stopped (articles rejected/dropped) and nothing noticed the missing writes.
  Created by `Loopctl.Workers.IngestionHealthWorker`.

  ## Anomaly Types

  - `capture_silence` -- an established source_type produced no new article for
    longer than the configured staleness threshold (writes STOPPED).
  - `high_reject_rate` -- writes of a source_type were ATTEMPTED but REJECTED at high
    rate over a rolling window (the OTHER outage signature: 409 title_conflict /
    validation drops that persist NO article row). Detected off the durable
    `ingestion_write_stats` rollup, not the `articles` table. For this type the
    freshness fields are repurposed: `sample_count` = total write attempts in the
    window; `hours_stale` is not meaningful (set to 0); `last_event_at` is nil. The
    reject figures (reject_rate, total_attempts, rejects, window_days,
    dominant_reason) live in `metadata`. `last_event_at` starts nil while the reject
    episode is ACTIVE and is stamped with the recovery time (episode ENDED) by
    `Loopctl.Knowledge.IngestionHealth.auto_resolve_recovered_reject_rate/1` — that
    stamp is what re-arms detection so a future reject storm re-fires.
  - `sweep_stalled` -- the US-39.5 channel-post retention sweep is NOT being enforced
    for this tenant: expired `channel_posts` rows (`expires_at` in the past) are still
    present far beyond the configured grace window (issue #498). Detected off
    `channel_posts`, not `articles`. The freshness fields are repurposed the same way
    as `high_reject_rate`: `sample_count` = the number of overdue expired rows;
    `hours_stale` = how many whole hours the OLDEST overdue row has outlived its
    `expires_at` (how long retention has been unenforced); `last_event_at` starts nil
    while the stall is ACTIVE and is stamped with the recovery time (no overdue rows
    remain) by `Loopctl.Knowledge.IngestionHealth.auto_resolve_recovered_sweep_stalled/1`
    — that stamp re-arms detection so a future stall re-fires. Recorded under the
    fixed sentinel `source_type` `IngestionHealth.sweep_source_type/0`
    (`"channel_post_sweep"`), since the sweep is not an article source_type.

  ## Fields

  - `source_type` -- the article `source_type` whose capture stream went silent /
    whose writes are being rejected
  - `anomaly_type` -- one of the types above
  - `last_event_at` -- `max(inserted_at)` of that source_type's articles (nil if none;
    always nil for `high_reject_rate`)
  - `hours_stale` -- whole hours between `last_event_at` and detection time (0 for
    `high_reject_rate`)
  - `sample_count` -- articles of that source_type within the recency/establishment
    window (capture_silence), or total write attempts in the window (high_reject_rate)
  - `resolved` -- whether the anomaly has been acknowledged/resolved
  - `archived` -- archived anomalies are excluded from the default list and
    suppress re-detection for a retired source_type until un-archived
  - `alerted` -- whether the out-of-band operator alert + webhook were fired.
    Makes notification AT-LEAST-ONCE: a worker crash between the atomic row
    insert and the post-commit enqueues leaves `alerted: false`, so a later run
    re-fires the notifications instead of losing them on the no-notify path.
  - `metadata` -- extensible JSONB map
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  # Extensible list — kept in sync with the `ingestion_anomalies_anomaly_type_check`
  # DB CHECK constraint (widened per new value via migration). A future detector can
  # be added here alongside a CHECK-widening migration.
  @anomaly_types [:capture_silence, :high_reject_rate, :sweep_stalled]

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :source_type,
             :anomaly_type,
             :last_event_at,
             :hours_stale,
             :sample_count,
             :resolved,
             :archived,
             :alerted,
             :metadata,
             :inserted_at,
             :updated_at
           ]}

  schema "ingestion_anomalies" do
    tenant_field()

    field :source_type, :string
    field :anomaly_type, Ecto.Enum, values: @anomaly_types
    field :last_event_at, :utc_datetime_usec
    field :hours_stale, :integer
    field :sample_count, :integer
    field :resolved, :boolean, default: false
    field :archived, :boolean, default: false
    field :alerted, :boolean, default: false
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc "The known anomaly types."
  @spec anomaly_types() :: [atom()]
  def anomaly_types, do: @anomaly_types

  @doc """
  Changeset for creating a capture-silence anomaly.

  The `tenant_id` is set programmatically and must not be in cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(anomaly \\ %__MODULE__{}, attrs) do
    anomaly
    |> cast(attrs, [
      :source_type,
      :anomaly_type,
      :last_event_at,
      :hours_stale,
      :sample_count,
      :resolved,
      :metadata
    ])
    |> validate_required([:source_type, :anomaly_type, :hours_stale, :sample_count])
    |> validate_inclusion(:anomaly_type, @anomaly_types)
    # Both types carry at least one sample: capture_silence needs >= 1 established
    # article; high_reject_rate needs >= 1 (in practice >= min_attempts) write attempt.
    |> validate_number(:sample_count, greater_than_or_equal_to: 1)
    |> validate_type_invariants()
    |> validate_metadata_size()
    |> foreign_key_constraint(:tenant_id)
  end

  # Per-type invariant on `hours_stale`. A capture-silence anomaly is, by definition,
  # a source_type that WENT stale — so it must be stale (> 0 hours); hours_stale: 0
  # ("not actually stale") is a logically impossible anomaly, rejected at the boundary
  # even though detection already only feeds stale figures. A high_reject_rate anomaly
  # has no staleness dimension (its evidence is the reject ratio in metadata), so
  # hours_stale is a non-meaningful 0 — allow >= 0. A sweep_stalled anomaly DOES carry a
  # staleness dimension (hours the oldest overdue row has outlived its expires_at) but it
  # is measured against a grace window that an operator may configure below one hour, so
  # a genuine stall can round to 0 whole hours — allow >= 0 rather than rejecting a real
  # retention failure at the boundary.
  defp validate_type_invariants(changeset) do
    case get_field(changeset, :anomaly_type) do
      :capture_silence -> validate_number(changeset, :hours_stale, greater_than: 0)
      :high_reject_rate -> validate_number(changeset, :hours_stale, greater_than_or_equal_to: 0)
      :sweep_stalled -> validate_number(changeset, :hours_stale, greater_than_or_equal_to: 0)
      _ -> changeset
    end
  end

  @doc """
  Changeset for resolving an anomaly.
  """
  @spec resolve_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def resolve_changeset(anomaly) do
    change(anomaly, resolved: true)
  end

  @doc """
  Changeset closing a RECOVERED `:high_reject_rate` anomaly.

  Sets `resolved: true` (closing an open row) AND stamps `last_event_at` with the
  recovery time. The `last_event_at` stamp marks the reject episode as ENDED so it
  no longer suppresses re-detection — a future storm for the same source_type
  re-fires. Applied by `IngestionHealth.auto_resolve_recovered_reject_rate/1`.
  """
  @spec reject_recovered_changeset(%__MODULE__{}, DateTime.t()) :: Ecto.Changeset.t()
  def reject_recovered_changeset(anomaly, recovered_at) do
    change(anomaly, resolved: true, last_event_at: recovered_at)
  end

  @doc """
  Changeset closing a RECOVERED `:sweep_stalled` anomaly.

  Structurally identical to `reject_recovered_changeset/2` (same episode shape: no
  natural "resumed" event, so recovery means "no longer a candidate"), kept as its own
  named function so the call sites read in the vocabulary of their detector. Sets
  `resolved: true` AND stamps `last_event_at` with the recovery time, marking the stall
  episode ENDED so it stops suppressing re-detection — a future stall re-fires. Applied
  by `IngestionHealth.auto_resolve_recovered_sweep_stalled/1`.
  """
  @spec sweep_recovered_changeset(%__MODULE__{}, DateTime.t()) :: Ecto.Changeset.t()
  def sweep_recovered_changeset(anomaly, recovered_at) do
    change(anomaly, resolved: true, last_event_at: recovered_at)
  end

  @doc """
  Changeset for archiving an anomaly.

  Archiving is the operator's escape hatch for a legitimately-retired
  `source_type`: an archived anomaly is excluded from the default list AND
  suppresses re-detection for that source_type (see
  `Loopctl.Workers.IngestionHealthWorker`), so a wound-down workflow is not
  re-flagged on every hourly run. It is REVERSIBLE via `unarchive_changeset/1`
  so a mistaken archive (e.g. a workflow later revived) can restore monitoring.
  """
  @spec archive_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def archive_changeset(anomaly) do
    change(anomaly, archived: true)
  end

  @doc """
  Changeset for un-archiving an anomaly — the inverse of `archive_changeset/1`.

  Restores monitoring for a source_type whose anomaly was archived: once
  `archived` is false again, `Loopctl.Workers.IngestionHealthWorker` no longer
  suppresses re-detection, so a revived workflow that goes silent is caught
  again. Without this the archive escape hatch would be a permanent, irreversible
  blind spot — the exact failure the dead-man's-switch exists to eliminate.
  """
  @spec unarchive_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def unarchive_changeset(anomaly) do
    change(anomaly, archived: false)
  end

  @doc """
  Changeset that records the out-of-band operator alert + webhook were fired.

  Used to make notification at-least-once: set only AFTER the post-commit
  enqueues succeed, so a crash before this leaves `alerted: false` and a later
  run re-fires the notifications rather than losing them.
  """
  @spec mark_alerted_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def mark_alerted_changeset(anomaly) do
    change(anomaly, alerted: true)
  end

  @metadata_max_bytes 65_536

  defp validate_metadata_size(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      if byte_size(Jason.encode!(value)) > @metadata_max_bytes,
        do: [metadata: "must be smaller than 64KB"],
        else: []
    end)
  end
end
