defmodule Loopctl.Workers.ChannelPostRescanWorker do
  @moduledoc """
  Oban cron worker that RETROACTIVELY re-scans live coordination-bus posts against the
  CURRENT `Loopctl.Security.SecretDenylist` pattern set and QUARANTINES the hits
  (issue #499).

  ## Why a rescan exists at all

  The US-39.1 denylist is a WRITE-TIME gate only, and self-described best-effort. Before
  this worker, remediation was purely reactive: someone noticed, then deleted the row.
  That leaves a specific, real amplification: a channel post lives 30 days AND is
  injected into every new session's context on that repo (the SessionStart TEAM CHANNEL
  block), so a credential that landed in a post is re-broadcast to every session for a
  month — and a pattern added to the denylist AFTER the post was written never
  re-examined it. This worker closes exactly that: a denylist update retroactively
  catches what the old pattern set missed.

  ## Quarantine, NEVER auto-delete

  A hit stamps `quarantined_at` (+ a `quarantine_reason` naming the offending FIELD
  names only — never the matched value) and the row is then excluded from EVERY
  coordination read (`recent/3`, `recent_page/3`, `directed_handoffs*`, `get_post/2`), so
  it stops being injected into new sessions. The ROW SURVIVES. The denylist is a
  prefix HEURISTIC, so a false positive that silently destroyed a coordination post
  would be strictly worse than a flagged one; hard redaction stays the deliberate
  operator action (`Loopctl.Coordination.delete_post/5`), which still resolves a
  quarantined post by id.

  ## Bounded, resumable, idempotent

  Mirrors `Loopctl.Workers.ChannelPostSweeper`'s deliberate NON-RECURSIVE,
  single-batch-per-run design: each `perform/1` examines AT MOST `@batch_size` posts
  (overridable downward via the `"limit"` job arg, clamped by `min(limit, @batch_size)`)
  so a large channel can never be walked inside one long transaction, and the crontab
  drains the rest over successive runs.

  Progress is durable rather than positional: every post examined in a run is stamped
  with `rescanned_at`, and the candidate query selects only posts that are live
  (`expires_at > now()`), not already quarantined, and either NEVER scanned or scanned
  BEFORE `SecretDenylist.revision/0`. So (a) successive runs advance instead of
  re-walking the same head batch, (b) an already-quarantined post is skipped — a re-run
  writes no second audit entry and raises no second alert, and (c) bumping
  `revision/0` alongside a new pattern makes the WHOLE live corpus eligible again.

  Runs on `Loopctl.AdminRepo` (BYPASSRLS): the candidate predicate is tenant-independent
  maintenance, exactly like the sweeper. Every downstream write (audit entry, anomaly)
  is still explicitly tenant-scoped to the offending post's own tenant.

  ## Accountability

  Each quarantine is an `Ecto.Multi` on AdminRepo: `Multi.update` (the stamp) +
  `Audit.log_in_multi` (`entity_type: "channel_post"`, `action: "quarantined"`,
  `actor_type: "system"`) in ONE transaction, so a detection can never be applied
  without its append-only, hash-chained audit record. A failed audit rolls the
  quarantine back and FAILS the job (Oban retries) — it is never converted into an
  `:ok`.

  ## Operator alert

  Per affected tenant per run, the same alert path #498 established: an
  `ingestion_anomalies` row (`anomaly_type: :secret_detected` under the reserved
  sentinel `source_type` `IngestionHealth.rescan_source_type/0`) written atomically with
  its `detected` audit entry, an always-on `Logger.error`, and an operator alert
  enqueued via `Loopctl.Workers.ScaleAlertDeliveryWorker`. `alerted` is flipped ONLY
  after the enqueue succeeds, so a crash in the gap leaves `alerted: false` and the next
  run re-fires (at-least-once). Anomalies surface for free through the existing
  `IngestionAnomalyController` / `get_ingestion_anomalies` read.

  ### Two deliberate differences from the #498 detectors

  1. **No auto-resolve.** A quarantined credential stays an OPEN operator item until a
     human reviews the post. Nothing about a later clean run means the leak was handled,
     so auto-closing would write a false `resolved` claim into the audit log.
  2. **A resolved anomaly does NOT suppress a new one.** For the episode detectors a
     resolved row means "the operator acknowledged this ongoing condition". Here every
     flag is a DISCRETE new leak, so after an operator resolves, the next detection
     creates and alerts again. Only ARCHIVING suppresses (the operator's explicit,
     reversible escape hatch).

  ### No tenant webhook (deliberate)

  Unlike `:sweep_stalled`, this anomaly is NOT pushed to per-tenant webhook
  subscribers. A credential detection is an operator/security event, and fanning
  "a post of yours carries a credential" out to arbitrary subscriber endpoints widens
  the very leak surface the quarantine just narrowed.

  ## Version skew

  `perform/1` probes the catalog for BOTH the `channel_posts.quarantined_at` column and
  an `ingestion_anomalies` CHECK that admits `secret_detected`. A crontab deploy that
  lands ahead of the migrations skips quietly (self-heals next run) instead of burning
  Oban retries on an UndefinedColumn / CHECK violation.

  ## Schedule

  Registered on the Oban crontab (hourly) in `Loopctl.ObanConfig.plugins/0`. Keep in
  sync with the crontab assertion in `oban_plugins_config_test.exs`.
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Knowledge.IngestionAnomaly
  alias Loopctl.Knowledge.IngestionHealth
  alias Loopctl.Security.SecretDenylist
  alias Loopctl.TelemetryEvents
  alias Loopctl.Workers.ScaleAlertDeliveryWorker

  # Smaller than the sweeper's 1000: a rescan pays a per-row regex walk over every
  # scanned field (bounded per field, but real CPU), where the sweep pays one bulk
  # DELETE. The hourly cadence drains a channel of any realistic size.
  @batch_size 500

  # Bound on the post-id sample carried in the operator alert / anomaly metadata: the
  # blast radius is reported as an exact count, so the id list is a debugging sample.
  @alert_post_sample 20

  @doc """
  Re-scans at most one bounded batch of live channel posts and quarantines any that
  carry a denylisted credential shape.

  Reads the `"limit"` job arg (a positive integer) as the per-run batch bound,
  defaulting to `#{@batch_size}`. Returns `:ok` whether or not anything was flagged
  (idempotent).

  Emits `Loopctl.TelemetryEvents.channel_post_rescanned/0` on EVERY successful run
  (zero-hit runs included). On a raise it logs at `error`, emits
  `channel_post_rescan_failed/0`, and RE-RAISES so Oban records the failure and retries;
  a non-exception `exit` is observed the same way and RE-EXITED.
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: args}) do
    if schema_ready?() do
      limit = batch_limit(args)
      observed(limit, fn -> rescan_batch(limit) end)
    else
      Logger.warning(
        "ChannelPostRescanWorker: quarantine columns / secret_detected anomaly type " <>
          "not present yet (migration pending); skipping this run"
      )

      :ok
    end
  end

  @doc false
  # The observability contract around ONE rescan attempt, factored out of `perform/1` so
  # BOTH failure shapes are exercisable by a test with a plain function (a genuine pool
  # `exit` is not reproducible under the Ecto sandbox). Same seam shape as
  # `Loopctl.Workers.ChannelPostSweeper.observed/2`. Not a public API.
  @spec observed(pos_integer(), (-> %{scanned: non_neg_integer(), quarantined: non_neg_integer()})) ::
          :ok
  def observed(limit, rescan) when is_function(rescan, 0) do
    %{scanned: scanned, quarantined: quarantined} = rescan.()

    # Always-on success signal, INCLUDING a zero-scan run: "rescanned, nothing due" and
    # "never ran" must be distinguishable from the outside.
    :telemetry.execute(
      TelemetryEvents.channel_post_rescanned(),
      %{scanned: scanned, quarantined: quarantined},
      %{limit: limit}
    )

    if quarantined > 0 do
      Logger.error(
        "ChannelPostRescanWorker quarantined #{quarantined} channel post(s) carrying a " <>
          "credential shape (scanned=#{scanned})"
      )
    end

    :ok
  rescue
    error ->
      # Observe, then RE-RAISE: Oban must still fail the job and retry (max_attempts: 3).
      # Never convert a failed rescan — or a failed quarantine audit — into an :ok.
      error_class = error.__struct__ |> Module.split() |> Enum.join(".")
      observe_failure(limit, error_class, Exception.message(error))

      reraise error, __STACKTRACE__
  catch
    # `rescue` only sees EXCEPTIONS. A DBConnection ownership/connection loss or a pool
    # checkout failure surfaces as an `exit`, which would otherwise bypass the whole
    # observability contract. Observe with a bounded `error_class` tag, then RE-EXIT.
    :exit, reason ->
      observe_failure(limit, "exit", inspect(reason))

      exit(reason)
  end

  # `detail` is a human message for the LOG only — it never enters telemetry metadata,
  # which stays bounded (limit + error_class).
  defp observe_failure(limit, error_class, detail) do
    Logger.error(
      "ChannelPostRescanWorker failed to rescan channel posts " <>
        "(limit=#{limit}, error_class=#{error_class}): #{detail}"
    )

    :telemetry.execute(
      TelemetryEvents.channel_post_rescan_failed(),
      %{count: 1},
      %{limit: limit, error_class: error_class}
    )
  end

  # One bounded batch: load the due posts, quarantine the offenders (each with its audit
  # entry, atomically), stamp the clean ones as scanned, then raise ONE operator alert per
  # affected tenant. Offenders are quarantined BEFORE the clean rows are stamped so a
  # crash mid-run leaves them due for the next run rather than silently marked scanned.
  defp rescan_batch(limit) do
    now = DateTime.utc_now()
    posts = due_posts(limit, now)

    offenders =
      posts
      |> Enum.map(&{&1, ChannelPost.secret_fields(&1)})
      |> Enum.reject(fn {_post, fields} -> fields == [] end)

    Enum.each(offenders, fn {post, fields} -> quarantine!(post, fields, now) end)

    stamp_scanned(posts, offenders, now)

    offenders
    |> Enum.group_by(fn {post, _fields} -> post.tenant_id end)
    |> Enum.each(&flag_tenant(&1, now))

    %{scanned: length(posts), quarantined: length(offenders)}
  end

  # Due = live (an expired post is already invisible and the TTL sweep is about to
  # hard-delete it, so re-scanning it is wasted work), not already quarantined, and not
  # yet examined under the CURRENT denylist revision. Oldest-scan-first with the
  # monotonic `seq` as tie-break gives a stable batch boundary across runs; served by
  # `channel_posts_rescan_idx`.
  defp due_posts(limit, now) do
    revision = SecretDenylist.revision()

    ChannelPost
    |> where([p], p.expires_at > ^now)
    |> where([p], is_nil(p.quarantined_at))
    |> where([p], is_nil(p.rescanned_at) or p.rescanned_at < ^revision)
    |> order_by([p], asc_nulls_first: p.rescanned_at, asc: p.seq)
    |> limit(^limit)
    |> AdminRepo.all()
  end

  # The stamp is a single bulk UPDATE over the CLEAN ids (offenders already carry
  # `rescanned_at` from their quarantine changeset, and are excluded from future
  # candidate queries by `quarantined_at` anyway).
  defp stamp_scanned(posts, offenders, now) do
    offender_ids = MapSet.new(offenders, fn {post, _fields} -> post.id end)

    case posts |> Enum.map(& &1.id) |> Enum.reject(&MapSet.member?(offender_ids, &1)) do
      [] ->
        :ok

      ids ->
        ChannelPost
        |> where([p], p.id in ^ids)
        |> AdminRepo.update_all(set: [rescanned_at: now, updated_at: now])

        :ok
    end
  end

  # Quarantine + audit in ONE transaction so a detection can never be applied without its
  # append-only audit record. A failed audit rolls the quarantine back and RAISES, so
  # Oban fails the job and retries — converting it to `:ok` would silently drop both the
  # accountability record and the operator's only per-post evidence.
  defp quarantine!(%ChannelPost{} = post, fields, now) do
    multi =
      Multi.new()
      |> Multi.update(:post, ChannelPost.quarantine_changeset(post, fields, now))
      |> Audit.log_in_multi(:audit, fn %{post: quarantined} ->
        quarantine_audit_attrs(quarantined, fields)
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{post: quarantined}} ->
        emit_quarantined(quarantined, fields)

      {:error, step, reason, _changes} ->
        raise "ChannelPostRescanWorker: failed to quarantine channel post #{post.id} " <>
                "(step #{inspect(step)}): #{inspect(reason)}"
    end
  end

  defp quarantine_audit_attrs(%ChannelPost{} = post, fields) do
    %{
      tenant_id: post.tenant_id,
      project_id: post.project_id,
      entity_type: "channel_post",
      entity_id: post.id,
      action: "quarantined",
      actor_type: "system",
      actor_label: "channel_post_rescan",
      # FIELD NAMES only — never the matched value, the body, or any post content.
      metadata: %{
        "reason" => "secret_denylist",
        "fields" => Enum.map(fields, &to_string/1),
        "author_agent_id" => post.agent_id,
        "denylist_revision" => DateTime.to_iso8601(SecretDenylist.revision())
      }
    }
  end

  # Sibling of the write-time `[:loopctl, :coordination, :secret_blocked]` signal, with
  # the same bounded metadata shape: ids + field NAMES, never a value.
  defp emit_quarantined(%ChannelPost{} = post, fields) do
    :telemetry.execute(
      TelemetryEvents.channel_post_quarantined(),
      %{count: 1},
      %{
        tenant_id: post.tenant_id,
        project_id: post.project_id,
        agent_id: post.agent_id,
        fields: Enum.map_join(fields, ",", &to_string/1)
      }
    )

    Logger.error(
      "coordination denylist RESCAN hit: quarantined post #{post.id} carrying a " <>
        "credential shape in #{Enum.map_join(fields, ",", &to_string/1)} " <>
        "(tenant=#{post.tenant_id} project=#{post.project_id} agent=#{post.agent_id})"
    )

    :ok
  end

  # --- Operator alert (the #498 anomaly path) ---

  defp flag_tenant({tenant_id, offenders}, now) do
    rows = existing_anomalies(tenant_id)
    live = Enum.find(rows, &(&1.resolved == false and &1.archived == false))

    cond do
      Enum.any?(rows, & &1.archived) ->
        # Operator archived this detector for the tenant — the reversible escape hatch.
        # The per-post quarantine + audit still happened; only the alert is suppressed.
        :suppressed

      live && not live.alerted ->
        # At-least-once recovery: the row was persisted + audited atomically but its
        # post-commit alert never fired (crash in the gap). Re-fire, then refresh.
        notify(tenant_id, live)
        refresh_anomaly(live, offenders)

      live ->
        # An unresolved detection is already raised for this tenant — accumulate the
        # figures without re-paging (anti-alarm-fatigue), exactly like the siblings.
        refresh_anomaly(live, offenders)

      true ->
        create_anomaly(tenant_id, offenders, now)
    end
  end

  defp existing_anomalies(tenant_id) do
    source_type = IngestionHealth.rescan_source_type()

    IngestionAnomaly
    |> where([a], a.tenant_id == ^tenant_id)
    |> where([a], a.source_type == ^source_type)
    |> where([a], a.anomaly_type == :secret_detected)
    |> AdminRepo.all()
  end

  # Accumulate: `sample_count` is the RUNNING total of posts quarantined for this tenant
  # while the anomaly stays open, so an operator sees the full blast radius rather than
  # only the most recent run's slice.
  defp refresh_anomaly(anomaly, offenders) do
    total = (anomaly.sample_count || 0) + length(offenders)

    case anomaly
         |> IngestionAnomaly.create_changeset(%{
           sample_count: total,
           metadata: anomaly_metadata(offenders, total)
         })
         |> AdminRepo.update() do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.warning(
          "ChannelPostRescanWorker: failed to update secret_detected anomaly " <>
            "#{anomaly.id}: #{inspect(changeset.errors)}"
        )

        anomaly
    end
  end

  defp create_anomaly(tenant_id, offenders, now) do
    count = length(offenders)

    changeset =
      IngestionAnomaly.create_changeset(
        %IngestionAnomaly{tenant_id: tenant_id},
        %{
          source_type: IngestionHealth.rescan_source_type(),
          anomaly_type: :secret_detected,
          # A detection is instantaneous — there is no staleness dimension.
          hours_stale: 0,
          sample_count: count,
          last_event_at: nil,
          metadata: anomaly_metadata(offenders, count)
        }
      )

    if changeset.valid? do
      insert_new_anomaly(tenant_id, changeset, now)
    else
      Logger.warning(
        "ChannelPostRescanWorker: invalid secret_detected anomaly for tenant " <>
          "#{tenant_id}, skipping: #{inspect(changeset.errors)}"
      )

      nil
    end
  end

  # Bounded metadata: an exact count, a SAMPLE of post ids, and the distinct offending
  # FIELD NAMES. Never a body, a value, or a match.
  defp anomaly_metadata(offenders, total) do
    %{
      "quarantined_count" => total,
      "post_ids" =>
        offenders |> Enum.map(fn {post, _fields} -> post.id end) |> Enum.take(@alert_post_sample),
      "fields" =>
        offenders
        |> Enum.flat_map(fn {_post, fields} -> Enum.map(fields, &to_string/1) end)
        |> Enum.uniq()
        |> Enum.sort(),
      "denylist_revision" => DateTime.to_iso8601(SecretDenylist.revision())
    }
  end

  # insert_all + on_conflict: :nothing against the unresolved unique partial index, with
  # the `detected` audit entry in the SAME transaction — the sibling detectors' shape.
  # {1, [row]} = we inserted (alert); {0, _} = a concurrent run already did.
  defp insert_new_anomaly(tenant_id, changeset, now) do
    entry =
      changeset
      |> Ecto.Changeset.apply_changes()
      |> Map.take([
        :tenant_id,
        :source_type,
        :anomaly_type,
        :last_event_at,
        :hours_stale,
        :sample_count,
        :resolved,
        :archived,
        :metadata
      ])
      |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})

    multi =
      Multi.new()
      |> Multi.run(:anomaly, fn repo, _changes ->
        case repo.insert_all(IngestionAnomaly, [entry],
               on_conflict: :nothing,
               conflict_target:
                 {:unsafe_fragment,
                  ~s|("tenant_id","source_type","anomaly_type") WHERE resolved = false|},
               returning: true
             ) do
          {1, [anomaly]} -> {:ok, anomaly}
          {0, _} -> {:ok, :conflict}
        end
      end)
      |> Multi.run(:audit, fn _repo, %{anomaly: anomaly} ->
        case anomaly do
          :conflict -> {:ok, :skipped}
          %IngestionAnomaly{} = row -> log_detected(tenant_id, row)
        end
      end)

    commit_anomaly(tenant_id, multi)
  end

  defp commit_anomaly(tenant_id, multi) do
    case AdminRepo.transaction(multi) do
      {:ok, %{anomaly: :conflict}} ->
        nil

      {:ok, %{anomaly: %IngestionAnomaly{} = anomaly}} ->
        notify(tenant_id, anomaly)
        anomaly

      {:error, step, reason, _changes} ->
        Logger.warning(
          "ChannelPostRescanWorker: failed to persist secret_detected anomaly for tenant " <>
            "#{tenant_id} (step #{inspect(step)}): #{inspect(reason)}"
        )

        nil
    end
  end

  defp log_detected(tenant_id, %IngestionAnomaly{} = anomaly) do
    md = anomaly.metadata || %{}

    Audit.create_log_entry(tenant_id, %{
      entity_type: "ingestion_anomaly",
      entity_id: anomaly.id,
      action: "detected",
      actor_type: "system",
      new_state: %{
        "anomaly_type" => to_string(anomaly.anomaly_type),
        "source_type" => anomaly.source_type,
        "quarantined_count" => md["quarantined_count"],
        "fields" => md["fields"]
      },
      metadata: %{
        "anomaly_id" => anomaly.id,
        "source_type" => anomaly.source_type,
        "anomaly_type" => to_string(anomaly.anomaly_type),
        "quarantined_count" => md["quarantined_count"]
      }
    })
  end

  # Always-on operator-visible alarm + the out-of-band alert, then flip `alerted` ONLY
  # after a successful enqueue (at-least-once: a crash in the gap leaves alerted=false
  # and the next run's recovery branch re-fires).
  defp notify(tenant_id, %IngestionAnomaly{} = anomaly) do
    md = anomaly.metadata || %{}

    Logger.error(
      "ChannelPostRescanWorker: credential shape detected on the coordination bus — " <>
        "tenant=#{tenant_id} quarantined_count=#{md["quarantined_count"]} " <>
        "fields=#{inspect(md["fields"])} anomaly_id=#{anomaly.id}"
    )

    payload = %{
      "alert" => "coordination.channel_post_secret_detected",
      "metric" => "coordination.channel_post_secret_detected.quarantined_count",
      "value" => md["quarantined_count"],
      # ANY detection is actionable, so the threshold is "more than zero".
      "threshold" => 0,
      "tenant_id" => tenant_id,
      "source_type" => anomaly.source_type,
      "fields" => md["fields"],
      "post_ids" => md["post_ids"],
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case enqueue_operator_alert(payload) do
      :ok ->
        mark_alerted(anomaly)

      :error ->
        Logger.error(
          "ChannelPostRescanWorker: secret_detected operator alert was NOT enqueued for " <>
            "tenant #{tenant_id}; anomaly #{anomaly.id} left unalerted for re-fire next run"
        )

        :error
    end
  end

  defp enqueue_operator_alert(payload) do
    case %{payload: payload} |> ScaleAlertDeliveryWorker.new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    # `Oban.insert/1` RAISES on some failures (no Oban instance running, an args encoding
    # fault). Swallowing it here is safe precisely because `alerted` has not been flipped
    # yet — the next run re-fires.
    error ->
      Logger.warning(
        "ChannelPostRescanWorker: failed to enqueue operator alert " <>
          "(#{inspect(error.__struct__)}): #{Exception.message(error)}"
      )

      :error
  end

  defp mark_alerted(anomaly) do
    case anomaly |> IngestionAnomaly.mark_alerted_changeset() |> AdminRepo.update() do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "ChannelPostRescanWorker: failed to mark anomaly #{anomaly.id} alerted: " <>
            "#{inspect(changeset.errors)}"
        )
    end
  end

  # --- Version-skew probes ---

  # Both halves of this feature are migration-gated: the quarantine columns on
  # channel_posts and the widened anomaly_type CHECK. Probing the catalog is crash-free,
  # so a crontab deploy ahead of either migration skips quietly and self-heals.
  defp schema_ready?, do: quarantine_column_present?() and secret_detected_check_ready?()

  defp quarantine_column_present? do
    case AdminRepo.query(
           "SELECT 1 FROM information_schema.columns WHERE table_name = 'channel_posts' " <>
             "AND column_name = 'quarantined_at'",
           []
         ) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  defp secret_detected_check_ready? do
    case AdminRepo.query(
           "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
             "WHERE conname = 'ingestion_anomalies_anomaly_type_check'",
           []
         ) do
      {:ok, %{rows: [[definition]]}} when is_binary(definition) ->
        String.contains?(definition, "secret_detected")

      _ ->
        false
    end
  end

  # The bound is data injected via job args (not app env), so a test — or an operator via
  # a one-off job — can tune the per-run cap without config changes. Clamped to
  # @batch_size: `stamp_scanned/3` passes the scanned ids as an explicit list to
  # `where(p.id in ^ids)` (one bind parameter each), so an unbounded limit could exceed
  # Postgres's 65535-parameter cap and crash every retry.
  defp batch_limit(%{"limit" => limit}) when is_integer(limit) and limit > 0,
    do: min(limit, @batch_size)

  defp batch_limit(_args), do: @batch_size
end
