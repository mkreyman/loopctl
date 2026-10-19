defmodule Loopctl.Changes.Events do
  @moduledoc """
  The change-events webhook's context (US-47.3, Epic 47 PRD §5): receipt, verification,
  idempotency, per-change ordering and audit of the events chg-server delivers, and the
  ingest half of gap and staleness reconciliation (`Loopctl.Changes.Reconcile` pulls).

  ## Authentication: one refusal for everything

  `receive_push/3` answers `{:error, :unauthorized}` — one answer, one 401 body — for an
  unknown source id, another tenant's or a revoked source, a suspended tenant, a `pr`-mode
  source or one holding no `change_events_secret`, a missing or wrong `X-Chg-Signature`, an
  `X-Chg-Timestamp` outside the window (`Loopctl.Changes.Signature`), an envelope naming
  another repository, and a source whose `chg_root_dispatch_id` is no longer a valid chg root
  (AC-47.3.7). Every refusal writes nothing, and is logged and counted (`event_refused/3`)
  with the reason, the source id when the source is known, and never the secret or the body.

  The source is found by the id in the URL, never by searching for a repository named in an
  unauthenticated body. The body is parsed only after its signature checks out.

  **The decision that counts is made inside the event's transaction.** The signature is first
  checked against the source as read before it, so a forged request is refused without
  opening a transaction or parsing the body. That check is only a cheap refusal: the
  transaction re-reads the source `FOR SHARE` (`Loopctl.Intake.hold_chg_source/3`, which also
  re-judges the tenant's status and the root by Intake's own rule) and verifies the signature
  AGAIN against the HELD row's `change_events_secret`. So a secret rotation, a revoke, a mode
  switch or a tenant suspension that commits between the two reads refuses the event with the
  same 401, writing nothing, rather than letting an event signed with the old secret apply.

  ## Idempotency

  `(tenant_id, repo, change_id, event_seq)` is a unique index, and the insert is
  `ON CONFLICT DO NOTHING`. An event already stored with the same content is a redelivery:
  `{:ok, %{outcome: :duplicate}}`, nothing written, nothing applied twice. One stored with
  DIFFERENT content under the same key is `{:error, :event_conflict}`, nothing written —
  chg's `event_seq` is immutable, so that is a chg fault to surface, not a redelivery to
  answer as accepted (the rule `threads.ex` applied to its keys, PRD §10).

  `repo` is the CANONICAL repository key (`repo_key/1`: the source's `repo_full_name`,
  downcased), never the envelope's spelling or the source's as stored. GitHub names are
  case-insensitive and the pull resolves the source that way
  (`Loopctl.Intake.chg_source_for_repo/2`), so a case-variant envelope, or the repository
  re-enrolled under another spelling, keys the SAME events and the SAME cursor. Every place a
  change is keyed derives it with `repo_key/1` — the events, the cursor, the binding a
  `submitted` event makes (`Loopctl.Changes.EventEffects`), and the pull
  (`Loopctl.Changes.Reconcile`) — and both tables CHECK `repo = lower(repo)`.

  ## Ordering

  Events apply in `event_seq` order per change, from 1, with no gaps. Every ingest first
  takes the change's `Loopctl.Changes.Cursor` row `FOR UPDATE` (creating it on the first
  event), so two events of one change never apply concurrently. An event whose turn has not
  come is stored with `applied_at` NULL (`:held`) and applies when the gap before it fills —
  in the same transaction as the event that fills it. Lock waits are bounded
  (`Loopctl.Runners.Capacity.set_lock_timeout!/2`) and contention answers `{:error, :busy}`
  (`Loopctl.Delivery.Stages.answering_busy/4`), a retryable 503: chg redelivers, and every
  write here is safe to resend.

  Applying is `Loopctl.Changes.EventEffects.apply_event/2`, the one seam the stage mapping
  (US-47.4) fills. Whatever it does, the event is marked applied and the cursor advances, so
  an unmapped kind never leaves a gap (AC-47.3.6).

  ## Audit

  Every applied event appends `change_event_applied` to the tenant's audit chain with its
  `repo`, `change_id`, `event_seq`, `sha`, `kind` and `revision` (AC-47.3.4), INSIDE the
  transaction that applies it, and is announced after commit. A held event appends when it
  applies; a duplicate appends nothing.

  ## No outbound call

  Nothing here reaches the network (AC-47.3.5). The pull is `Loopctl.Changes.Reconcile`'s,
  run from an Oban job.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AuditChain
  alias Loopctl.Changes.Cursor
  alias Loopctl.Changes.Envelope
  alias Loopctl.Changes.Event
  alias Loopctl.Changes.EventEffects
  alias Loopctl.Changes.Signature
  alias Loopctl.Delivery.Stages
  alias Loopctl.Intake
  alias Loopctl.Intake.Source
  alias Loopctl.Repo
  alias Loopctl.Runners.Capacity

  # The largest event body accepted, held here for the guard (`LoopctlWeb.Plugs.IntakeRawBody`)
  # and the operation spec (`LoopctlWeb.ChangeEventController`) alike, so they cannot drift. An
  # envelope is a few hundred bytes; the largest `data` chg sends is `reverted`'s list of
  # failing test ids, and 256 KiB holds thousands of them.
  @max_body_bytes 262_144

  # The same work for an unknown source as for a known one, so timing does not say which.
  @timing_key :crypto.hash(:sha256, "loopctl-change-events-unknown-source")

  @type outcome :: :applied | :held | :duplicate
  @type result :: %{outcome: outcome(), applied_seq: non_neg_integer()}
  @type push_input :: %{
          required(:raw_body) => binary(),
          optional(:timestamp) => String.t() | nil,
          optional(:signature) => String.t() | nil
        }

  @doc "The largest change-event body accepted, in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc """
  The canonical repository key a change is stored under: `repo_full_name` downcased. The one
  derivation every change-keyed read and write uses.
  """
  @spec repo_key(String.t()) :: String.t()
  def repo_key(repo_full_name) when is_binary(repo_full_name),
    do: String.downcase(repo_full_name)

  @doc """
  Receives one webhook delivery for `source_id`.

  `opts`: `:now` (unix seconds; the clock the window is judged by), `:lock_timeout_ms`
  (`Capacity.lock_timeout_ms/1`), `:before_hold` (a 0-arity function run after the
  pre-check and before the event's transaction, so a test can commit a rotation or a
  suspension in exactly that window) and `:escalate` (passed to
  `Loopctl.Changes.EventEffects.apply_event/3`). All are inputs for tests only; production
  passes nothing.
  """
  @spec receive_push(term(), push_input(), keyword()) ::
          {:ok, result()}
          | {:error,
             :unauthorized | {:bad_request, String.t()} | :event_conflict | :busy | :apply_failed}
  def receive_push(source_id, %{raw_body: raw_body} = input, opts \\ [])
      when is_binary(raw_body) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, source} <- authenticate(source_id, input, now),
         {:ok, envelope} <- decode(raw_body),
         :ok <- same_repository(source, envelope) do
      Logger.metadata(tenant_id: source.tenant_id)
      Keyword.get(opts, :before_hold, fn -> :ok end).()

      source.tenant_id
      |> in_held_source(source, opts, fn held ->
        reauthenticate!(held, input, now)
        ingest_one(held, envelope, "push", DateTime.utc_now(), effects_opts(opts))
      end)
      |> finish_push(source, envelope)
    end
  end

  # The authoritative check: the signature against the secret of the row HELD in this
  # transaction. A refusal rolls back to the same `{:refused, reason}` the hold answers.
  defp reauthenticate!(%Source{change_events_secret: secret}, input, now) do
    case Signature.verify(secret, input[:timestamp], input.raw_body, input[:signature], now) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:refused, reason})
    end
  end

  @doc """
  Ingests envelopes `Loopctl.Changes.Reconcile` pulled for one change of `source`, in one
  transaction under the same source hold, cursor lock and ordering as a push. A pulled event
  that conflicts with a stored one is skipped and logged rather than failing the page.

  Answers `{:ok, %{applied_seq: n}}` — the change's cursor after the page, `nil` when every
  envelope was skipped — or the refusal `{:error, :unauthorized}` when the source or its root
  is no longer valid.
  """
  @spec ingest_pulled(Source.t(), [Envelope.t()], keyword()) ::
          {:ok, %{applied_seq: non_neg_integer() | nil}}
          | {:error, :unauthorized | :busy | :apply_failed}
  def ingest_pulled(%Source{} = source, envelopes, opts \\ []) when is_list(envelopes) do
    now = DateTime.utc_now()

    source.tenant_id
    |> in_held_source(source, opts, fn held ->
      Enum.reduce(envelopes, {nil, []}, &ingest_pulled_one(held, &1, now, &2, opts))
    end)
    |> case do
      {:ok, {applied_seq, pending}} ->
        after_commit(pending)
        {:ok, %{applied_seq: applied_seq}}

      {:error, {:refused, reason}} ->
        event_refused(source.id, source, reason)
        {:error, :unauthorized}

      {:error, reason} ->
        failed(source, reason)
    end
  end

  defp ingest_pulled_one(source, envelope, now, {applied_seq, pending}, opts) do
    case ingest_one(source, envelope, "pull", now, effects_opts(opts)) do
      {:conflict, _existing} ->
        log_conflict(source, envelope, "pull")
        {applied_seq, pending}

      {_outcome, applied_seq, more} ->
        {applied_seq, pending ++ more}
    end
  end

  @doc """
  The tenant's stored events of one change, in `event_seq` order. `[]` for another tenant's.
  `repo` is matched by `repo_key/1`, so any spelling of the repository reads the same change.
  """
  @spec list_events(Ecto.UUID.t(), String.t(), String.t()) :: [Event.t()]
  def list_events(tenant_id, repo, change_id)
      when is_binary(tenant_id) and is_binary(repo) and is_binary(change_id) do
    repo = repo_key(repo)

    {:ok, events} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.all(
          from e in Event,
            where: e.tenant_id == ^tenant_id and e.repo == ^repo and e.change_id == ^change_id,
            order_by: [asc: e.event_seq]
        )
      end)

    events
  end

  @doc """
  The tenant's cursor for one change, or `nil` (another tenant's included). `repo` is matched
  by `repo_key/1`.
  """
  @spec get_cursor(Ecto.UUID.t(), String.t(), String.t()) :: Cursor.t() | nil
  def get_cursor(tenant_id, repo, change_id)
      when is_binary(tenant_id) and is_binary(repo) and is_binary(change_id) do
    repo = repo_key(repo)

    {:ok, cursor} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.one(
          from c in Cursor,
            where: c.tenant_id == ^tenant_id and c.repo == ^repo and c.change_id == ^change_id
        )
      end)

    cursor
  end

  @doc """
  Counts and logs one refused event: `[:loopctl, :changes, :event_refused]`, tagged with the
  source id when the source is KNOWN (`"unknown"` otherwise, so an attacker-chosen id cannot
  grow the tag set) and the reason. The log names the URL's id, bounded, and never the
  secret or the body.
  """
  @spec event_refused(term(), Source.t() | nil, atom()) :: :ok
  def event_refused(source_id, source, reason) do
    tag = if source, do: source.id, else: "unknown"

    :telemetry.execute([:loopctl, :changes, :event_refused], %{count: 1}, %{
      source: tag,
      reason: reason
    })

    Logger.warning(
      "change event refused: source_id=#{inspect(bounded(source_id))} reason=#{reason}"
    )
  end

  # ── authentication ──────────────────────────────────────────────────────────

  defp authenticate(source_id, input, now) do
    timestamp = input[:timestamp]
    signature = input[:signature]

    case Intake.delivery_source(source_id) do
      %Source{mode: :chg, change_events_secret: secret} = source when is_binary(secret) ->
        case Signature.verify(secret, timestamp, input.raw_body, signature, now) do
          :ok -> {:ok, source}
          {:error, reason} -> refuse(source_id, source, reason)
        end

      %Source{} = source ->
        _ = Signature.verify(@timing_key, timestamp, input.raw_body, signature, now)
        refuse(source_id, source, :not_chg_source)

      nil ->
        _ = Signature.verify(@timing_key, timestamp, input.raw_body, signature, now)
        refuse(source_id, nil, :unknown_source)
    end
  end

  defp refuse(source_id, source, reason) do
    event_refused(source_id, source, reason)
    {:error, :unauthorized}
  end

  defp decode(raw_body) do
    case Envelope.decode(raw_body) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, :invalid_event} -> {:error, {:bad_request, "invalid_event"}}
    end
  end

  # An envelope for another repository is refused like a bad signature: the source's secret
  # authenticates deliveries ABOUT its repository and nothing else.
  defp same_repository(%Source{repo_full_name: repo} = source, %{repo: named}) do
    if repo_key(named) == repo_key(repo),
      do: :ok,
      else: refuse(source.id, source, :repository_mismatch)
  end

  # ── the transaction ─────────────────────────────────────────────────────────

  # The source is re-read FOR SHARE, and its tenant and root judged, in the same transaction
  # that writes, so a revoke, rotation or suspension commits first and refuses this event, or
  # waits for it.
  defp in_held_source(tenant_id, %Source{id: source_id}, opts, fun) do
    Stages.answering_busy(tenant_id, [:loopctl, :changes, :event_busy], "change event", fn ->
      Repo.with_tenant(tenant_id, fn -> held_source_body(tenant_id, source_id, opts, fun) end)
    end)
  end

  defp held_source_body(tenant_id, source_id, opts, fun) do
    Capacity.set_lock_timeout!(Repo, opts)

    case Intake.hold_chg_source(Repo, tenant_id, source_id) do
      {:ok, held} -> fun.(held)
      {:error, reason} -> Repo.rollback({:refused, reason})
    end
  end

  defp finish_push({:ok, {:conflict, _existing}}, source, envelope) do
    log_conflict(source, envelope, "push")
    {:error, :event_conflict}
  end

  defp finish_push({:ok, {outcome, applied_seq, pending}}, _source, _envelope) do
    after_commit(pending)
    {:ok, %{outcome: outcome, applied_seq: applied_seq}}
  end

  defp finish_push({:error, {:refused, reason}}, source, _envelope) do
    event_refused(source.id, source, reason)
    {:error, :unauthorized}
  end

  defp finish_push({:error, reason}, source, _envelope), do: failed(source, reason)

  # `:busy` is the lock bound; a bind that lost a race it cannot lose under the cursor lock is
  # answered the same way, so chg redelivers and the redelivery reads the winner.
  defp failed(_source, :busy), do: {:error, :busy}
  defp failed(_source, {:lost_to, _winner}), do: {:error, :busy}
  defp failed(_source, :change_bound_to_other_story), do: {:error, :busy}

  defp failed(source, reason) do
    Logger.error(
      "change event could not be applied: source_id=#{source.id} reason=#{inspect(reason)}"
    )

    {:error, :apply_failed}
  end

  defp after_commit(pending) do
    Enum.each(pending, fn
      {:entry, entry} -> AuditChain.announce_entry(entry)
      {:effects, effects} -> EventEffects.after_commit(effects)
    end)
  end

  defp log_conflict(source, envelope, via) do
    Logger.error(
      "change event conflicts with the stored event under the same key: " <>
        "source_id=#{source.id} change_id=#{inspect(envelope.change_id)} " <>
        "event_seq=#{envelope.event_seq} via=#{via}"
    )
  end

  # ── ingest: lock, insert, apply ─────────────────────────────────────────────

  # Inside the tenant transaction. Answers `{outcome, applied_seq, pending}` or
  # `{:conflict, existing}`.
  defp ingest_one(%Source{} = source, envelope, via, now, effects_opts) do
    key = %{
      tenant_id: source.tenant_id,
      repo: repo_key(source.repo_full_name),
      change_id: envelope.change_id
    }

    cursor = lock_cursor(source, key, now)

    case insert_event(source, key, envelope, via, now) do
      :inserted ->
        {cursor, pending} = apply_ready(cursor, [], effects_opts)
        touch_cursor(cursor, source, now)
        outcome = if cursor.applied_seq >= envelope.event_seq, do: :applied, else: :held
        {outcome, cursor.applied_seq, pending}

      {:existing, existing} ->
        if same_event?(existing, envelope),
          do: {:duplicate, cursor.applied_seq, []},
          else: {:conflict, existing}
    end
  end

  # The row is created by the change's first event and locked by every one after. Two first
  # events race on the unique index: the loser waits for the winner's commit (bounded by the
  # lock timeout), inserts nothing, and then locks the winner's row.
  defp lock_cursor(source, key, now) do
    Repo.insert_all(
      Cursor,
      [
        Map.merge(key, %{
          id: Ecto.UUID.generate(),
          source_id: source.id,
          applied_seq: 0,
          last_event_at: now,
          inserted_at: now,
          updated_at: now
        })
      ],
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :repo, :change_id]
    )

    Repo.one!(
      from c in Cursor,
        where:
          c.tenant_id == ^key.tenant_id and c.repo == ^key.repo and
            c.change_id == ^key.change_id,
        lock: "FOR UPDATE"
    )
  end

  defp insert_event(source, key, envelope, via, now) do
    row =
      Map.merge(key, %{
        id: Ecto.UUID.generate(),
        source_id: source.id,
        event_seq: envelope.event_seq,
        kind: envelope.kind,
        revision: envelope.revision,
        sha: envelope.sha,
        occurred_at: envelope.occurred_at,
        data: envelope.data,
        received_via: via,
        inserted_at: now,
        updated_at: now
      })

    case Repo.insert_all(Event, [row],
           on_conflict: :nothing,
           conflict_target: [:tenant_id, :repo, :change_id, :event_seq]
         ) do
      {1, _} -> :inserted
      {0, _} -> {:existing, Repo.one!(event_query(key, envelope.event_seq))}
    end
  end

  defp event_query(key, seq) do
    from e in Event,
      where:
        e.tenant_id == ^key.tenant_id and e.repo == ^key.repo and
          e.change_id == ^key.change_id and e.event_seq == ^seq
  end

  # A redelivery carries the same event; a stored row read back from jsonb compares equal to
  # the decoded body on every field chg sets.
  defp same_event?(%Event{} = e, envelope) do
    e.kind == envelope.kind and e.revision == envelope.revision and e.sha == envelope.sha and
      DateTime.compare(e.occurred_at, envelope.occurred_at) == :eq and e.data == envelope.data
  end

  # Applies the stored events from `applied_seq + 1` for as long as the next one is there.
  defp apply_ready(%Cursor{} = cursor, pending, effects_opts) do
    next = cursor.applied_seq + 1
    key = Map.take(cursor, [:tenant_id, :repo, :change_id])

    case Repo.one(event_query(key, next)) do
      nil ->
        {cursor, pending}

      %Event{} = event ->
        more = apply_event(event, effects_opts)
        apply_ready(%{cursor | applied_seq: next}, pending ++ more, effects_opts)
    end
  end

  defp apply_event(%Event{tenant_id: tenant_id} = event, effects_opts) do
    {:ok, effect, effects} = EventEffects.apply_event(tenant_id, event, effects_opts)
    now = DateTime.utc_now()

    {1, _} =
      Repo.update_all(
        from(e in Event, where: e.id == ^event.id and e.tenant_id == ^tenant_id),
        set: [applied_at: now, effect: effect, updated_at: now]
      )

    case AuditChain.append_in_tenant_transaction(tenant_id, %{
           action: "change_event_applied",
           actor_lineage: [],
           entity_type: "change_event",
           entity_id: event.id,
           payload: %{
             "repo" => event.repo,
             "change_id" => event.change_id,
             "event_seq" => event.event_seq,
             "sha" => event.sha,
             "kind" => event.kind,
             "revision" => event.revision,
             "received_via" => event.received_via,
             "effect" => effect
           }
         }) do
      {:ok, entry} -> [{:effects, effects}, {:entry, entry}]
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # What of a caller's `opts` reaches `EventEffects.apply_event/3`.
  defp effects_opts(opts), do: Keyword.take(opts, [:escalate])

  defp touch_cursor(%Cursor{} = cursor, source, now) do
    {1, _} =
      Repo.update_all(
        from(c in Cursor, where: c.id == ^cursor.id and c.tenant_id == ^cursor.tenant_id),
        set: [
          applied_seq: cursor.applied_seq,
          last_event_at: now,
          source_id: source.id,
          updated_at: now
        ]
      )

    :ok
  end

  defp bounded(value) when is_binary(value), do: String.slice(value, 0, 64)
  defp bounded(_value), do: nil
end
