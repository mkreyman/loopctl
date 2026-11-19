defmodule Loopctl.Changes.Events do
  @moduledoc """
  The change-events webhook's context (US-47.3, Epic 47 PRD §5; US-50.2): receipt,
  verification, idempotency, per-change ordering and audit of the events the fleet's chg
  outboxes deliver, and the change's cursor that tells a sender what to resend.

  ## The cursor: how a gap fills

  loopctl cannot reach the senders, so it never pulls. Every answer to a push carries the
  change's cursor, `%{applied_through: n, held: [seq...]}`, read in the transaction that
  applied the event, and `read_cursor/3` answers it alone for a signed GET. A sender that
  sees `held` non-empty resends from `applied_through + 1`. `held` lists at most
  `@max_held` seqs, lowest first; past that the gap is not the sender's only problem.

  An applied event also clears the change's `attention` flag
  (`Loopctl.Changes.Reconcile`): a `stale` change has heard from its sender, and a `gap`
  change whose held events have all applied is whole again.

  ## Authentication: one refusal for everything

  `receive_push/3` answers `{:error, :unauthorized}` — one answer, one 401 body — for an
  unknown source id, another tenant's or a revoked source, a suspended tenant, a source
  holding no `change_events_secret`, a missing or wrong `X-Chg-Signature`, an
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

  ## Sending is not routing (issue #1047)

  A source in ANY mode that holds both chg credentials authenticates here: `chg`, a `pr`
  source whose repository merges through pull requests, and a `ledger` source on a kb scope or a work project.
  What its events DO is decided by the mode of the source HELD in the transaction that applies
  them:

  - under `chg`, an event goes through `Loopctl.Changes.EventEffects` — it binds a change,
    moves a stage, escalates `:review_missing` — and is stored `routed: true`;
  - under any other mode it is stored, ordered, cursored and audited exactly the same, but
    applied with NO effect (`%{"effect" => "recorded", "routed" => false}`) and stored
    `routed: false`.

  This is what keeps a `pr` repository's events from bypassing its own route. A `landed` event
  would otherwise move a pull-request story `ci -> merged` around the merge precondition and
  the verify@1 verifier, a `submitted` event would bind the story to a change and make it a
  chg story whose reviews a chg root's children may record, and a `review_approved` +
  `check_passed` pair would move it to `ci`. None of that runs, and every reader that treats an
  applied event as EVIDENCE — the landed revision (`Loopctl.Changes.Landings`), the bound
  revision a chg review must name and a minted reviewer's revision
  (`Loopctl.Changes.ReviewCustody`), the revision a review dispatch is minted for
  (`Loopctl.Changes.ReviewDispatches`) and the earlier events a stage move pairs with
  (`EventEffects`) — reads `routed` events only, so an unrouted one cannot stand in for a routed
  one after a later switch to `chg`. The one exception is evidence AGAINST a gate: a `reverted`
  event counts in every mode (`Loopctl.Changes.TrunkEvidence`), because ignoring it would
  verify a landing that is no longer on trunk.

  The mode is read at APPLICATION, not at receipt: an event held behind a gap is applied under
  whatever mode the source has when the gap fills. A switch to `chg` is the deliberate act that
  opens the route, so an event applied after it is routed. A switch away does not move a change
  the route has already acted on: while the source is not `chg`, an event for a change with any
  applied routed event is refused with the same 401, writing nothing, so the sender keeps it
  until the source is `chg` again. Only a change that began off the route is recorded unrouted.

  ## Idempotency

  `(tenant_id, repo, change_id, event_seq)` is a unique index, and the insert is
  `ON CONFLICT DO NOTHING`. An event already stored with the same content is a redelivery:
  `{:ok, %{outcome: :duplicate}}`, nothing written, nothing applied twice. One stored with
  DIFFERENT content under the same key is `{:error, :event_conflict}`, nothing written —
  chg's `event_seq` is immutable, so that is a chg fault to surface, not a redelivery to
  answer as accepted (the rule `threads.ex` applied to its keys, PRD §10).

  `repo` is the CANONICAL repository key (`repo_key/1`: the source's `repo_full_name`,
  downcased), never the envelope's spelling or the source's as stored. GitHub names are
  case-insensitive, so a case-variant envelope, or the repository re-enrolled under another
  spelling, keys the SAME events and the SAME cursor. Every place a change is keyed derives it
  with `repo_key/1` — the events, the cursor and the binding a `submitted` event makes
  (`Loopctl.Changes.EventEffects`) — and both tables CHECK `repo = lower(repo)`.

  ## Ordering

  Events apply in `event_seq` order per change, from 1, with no gaps. Every ingest first
  takes the change's `Loopctl.Changes.Cursor` row `FOR UPDATE` (creating it on the first
  event), so two events of one change never apply concurrently. An event whose turn has not
  come is stored with `applied_at` NULL (`:held`) and applies when the gap before it fills —
  in the same transaction as the event that fills it. Lock waits are bounded
  (`Loopctl.Runners.Capacity.set_lock_timeout!/2`) and contention answers `{:error, :busy}`
  (`Loopctl.Delivery.Stages.answering_busy/4`), a retryable 503: the sender redelivers, and
  every write here is safe to resend.

  Applying is `Loopctl.Changes.EventEffects.apply_event/2`, the one seam the stage mapping
  (US-47.4) fills. Whatever it does, the event is marked applied and the cursor advances, so
  an unmapped kind never leaves a gap (AC-47.3.6).

  ## Audit

  Every applied event appends `change_event_applied` to the tenant's audit chain with its
  `repo`, `change_id`, `event_seq`, `sha`, `kind` and `revision` (AC-47.3.4), INSIDE the
  transaction that applies it, and is announced after commit. A held event appends when it
  applies; a duplicate appends nothing.

  ## No outbound call

  Nothing here reaches the network (AC-47.3.5).
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

  # The most held seqs a cursor lists.
  @max_held 500

  @type outcome :: :applied | :held | :duplicate
  @type cursor_view :: %{
          change_id: String.t(),
          applied_through: non_neg_integer(),
          held: [pos_integer()]
        }
  @type result :: %{outcome: outcome(), applied_seq: non_neg_integer(), cursor: cursor_view()}
  @type cursor_input :: %{
          required(:path) => String.t(),
          required(:query) => String.t(),
          required(:change_id) => String.t() | nil,
          optional(:timestamp) => String.t() | nil,
          optional(:signature) => String.t() | nil
        }
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
  Answers one change's cursor to a signed GET for `source_id` (US-50.2):
  `{:ok, %{change_id:, applied_through:, held:}}`.

  The signature covers `Signature.get_body(path, query)` exactly as the request sent them, and
  every refusal is the same `{:error, :unauthorized}` a push gets, judged the same way: the
  pre-check, then the source held `FOR SHARE` with its tenant and root re-judged and the
  signature verified again against the held row. A change loopctl has never seen answers
  `applied_through: 0, held: []` rather than a not-found, so a change id cannot be probed.
  A missing `change_id` is `{:error, {:bad_request, "change_id_required"}}`, judged after the
  signature.
  """
  @spec read_cursor(term(), cursor_input(), keyword()) ::
          {:ok, cursor_view()}
          | {:error, :unauthorized | {:bad_request, String.t()} | :busy | :apply_failed}
  def read_cursor(source_id, %{path: path, query: query} = input, opts \\ [])
      when is_binary(path) and is_binary(query) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    signed = %{
      raw_body: Signature.get_body(path, query),
      timestamp: input[:timestamp],
      signature: input[:signature]
    }

    signed(source_id, signed, Keyword.put(opts, :now, now), fn held ->
      case required_change_id(input[:change_id]) do
        {:ok, change_id} -> cursor_view(held.tenant_id, repo_key(held.repo_full_name), change_id)
        {:error, bad_request} -> Repo.rollback(bad_request)
      end
    end)
  end

  @doc """
  Runs `fun.(held_source)` for one signed request to `source_id`, and is the ONE way a chg
  sender's request is authenticated: the change-event push, the cursor read (US-50.2) and the
  ledger batch (US-50.1) all come through here or through `receive_push/3`, which judges the
  same way.

  `input` carries `:raw_body` (the bytes the signature covers), `:timestamp` and
  `:signature`. The signature is checked against the source's secret, then the source is held
  `FOR SHARE` in a tenant transaction, its tenant and chg root judged, and the signature
  verified again against the held row; `fun` runs inside that transaction. Every refusal is
  `{:error, :unauthorized}`, counted by `event_refused/3`. `fun` may `Repo.rollback/1` with
  `{:bad_request, code}` or `{:rejected, http_status, code}`, which come back as
  `{:error, ...}` unchanged, or with `{:refused, reason}`, which is the 401;
  `{:unrecorded_dispatch, tenant_id, dispatch_id, reason}` also comes back unchanged, so the
  caller can revoke a dispatch committed apart from the rolled-back transaction. Any other
  rollback is `{:error, :busy}` or `{:error, :apply_failed}` as for a push.

  `opts`: `:now` and `:lock_timeout_ms`, as for `receive_push/3`.
  """
  @spec signed(term(), push_input(), keyword(), (Source.t() -> result)) ::
          {:ok, result}
          | {:error,
             :unauthorized
             | {:bad_request, String.t()}
             | {:rejected, pos_integer(), String.t()}
             | {:unrecorded_dispatch, Ecto.UUID.t(), Ecto.UUID.t(), term()}
             | :busy
             | :apply_failed}
        when result: term()
  def signed(source_id, %{raw_body: raw_body} = input, opts, fun)
      when is_binary(raw_body) and is_function(fun, 1) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, source} <- authenticate(source_id, input, now) do
      Logger.metadata(tenant_id: source.tenant_id)

      source.tenant_id
      |> in_held_source(source, opts, fn held ->
        reauthenticate!(held, input, now)
        fun.(held)
      end)
      |> case do
        {:ok, value} ->
          {:ok, value}

        {:error, {:refused, reason}} ->
          event_refused(source.id, source, reason)
          {:error, :unauthorized}

        {:error, {:bad_request, code}} when is_binary(code) ->
          {:error, {:bad_request, code}}

        {:error, {:rejected, status, code}} when is_integer(status) and is_binary(code) ->
          {:error, {:rejected, status, code}}

        {:error, {:unrecorded_dispatch, _tenant_id, _dispatch_id, _reason} = unrecorded} ->
          {:error, unrecorded}

        {:error, reason} ->
          failed(source, reason)
      end
    end
  end

  defp required_change_id(change_id) when is_binary(change_id) and change_id != "",
    do: {:ok, change_id}

  defp required_change_id(_change_id), do: {:error, {:bad_request, "change_id_required"}}

  # Inside a tenant transaction: the change's applied seq and its stored, unapplied seqs.
  defp cursor_view(tenant_id, repo, change_id) do
    applied =
      Repo.one(
        from c in Cursor,
          where: c.tenant_id == ^tenant_id and c.repo == ^repo and c.change_id == ^change_id,
          select: c.applied_seq
      ) || 0

    %{
      change_id: change_id,
      applied_through: applied,
      held: held_seqs(%{tenant_id: tenant_id, repo: repo, change_id: change_id})
    }
  end

  defp held_seqs(key) do
    Repo.all(
      from e in Event,
        where:
          e.tenant_id == ^key.tenant_id and e.repo == ^key.repo and
            e.change_id == ^key.change_id and is_nil(e.applied_at),
        order_by: [asc: e.event_seq],
        limit: @max_held,
        select: e.event_seq
    )
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
      %Source{change_events_secret: secret} = source when is_binary(secret) ->
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

  defp finish_push({:ok, {outcome, view, pending}}, _source, _envelope) do
    after_commit(pending)
    {:ok, %{outcome: outcome, applied_seq: view.applied_through, cursor: view}}
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

  # Inside the tenant transaction. Answers `{outcome, cursor_view, pending}` or
  # `{:conflict, existing}`.
  defp ingest_one(%Source{} = source, envelope, via, now, effects_opts) do
    key = %{
      tenant_id: source.tenant_id,
      repo: repo_key(source.repo_full_name),
      change_id: envelope.change_id
    }

    cursor = lock_cursor(source, key, now)
    # The HELD source's mode, read FOR SHARE in this transaction: a switch commits first and is
    # seen, or waits for this event.
    routed = routed?(source)
    unless routed, do: refuse_routed_change!(key)
    effects_opts = Keyword.put(effects_opts, :routed, routed)

    case insert_event(source, key, envelope, via, now) do
      :inserted ->
        {cursor, pending} = apply_ready(cursor, [], effects_opts)
        held = held_seqs(key)
        touch_cursor(cursor, held, source, now)
        outcome = if cursor.applied_seq >= envelope.event_seq, do: :applied, else: :held
        {outcome, view(key, cursor.applied_seq, held), pending}

      {:existing, existing} ->
        if same_event?(existing, envelope),
          do: {:duplicate, view(key, cursor.applied_seq, held_seqs(key)), []},
          else: {:conflict, existing}
    end
  end

  defp view(key, applied_seq, held),
    do: %{change_id: key.change_id, applied_through: applied_seq, held: held}

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
    {routed, effects_opts} = Keyword.pop(effects_opts, :routed, false)
    {:ok, effect, effects} = effect_of(routed, tenant_id, event, effects_opts)
    now = DateTime.utc_now()

    {1, _} =
      Repo.update_all(
        from(e in Event, where: e.id == ^event.id and e.tenant_id == ^tenant_id),
        set: [applied_at: now, effect: effect, routed: routed, updated_at: now]
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

  # Only a `chg` source routes its events (see "Sending is not routing" above). Any other mode's
  # event is recorded and does nothing: no binding, no stage, no escalation.
  defp effect_of(true, tenant_id, event, effects_opts),
    do: EventEffects.apply_event(tenant_id, event, effects_opts)

  defp effect_of(false, _tenant_id, _event, _effects_opts),
    do: {:ok, %{"effect" => "recorded", "routed" => false}, []}

  defp routed?(%Source{mode: :chg}), do: true
  defp routed?(%Source{}), do: false

  # A change the `chg` route has already acted on stays on that route. While its source is not
  # `chg` (a temporary switch to `pr`, or one made before this deploy that kept the
  # credentials), its next event is refused with the 401 it got before a `pr` source could send
  # at all, writing nothing, so the sender keeps it and redelivers it once the source is `chg`
  # again. Applying it unrouted instead would move the cursor past it, and no later reader
  # counts an unrouted event: a `landed` would never land the story. Judged under the change's
  # cursor lock, so it cannot race the change's own events.
  defp refuse_routed_change!(key) do
    if Repo.exists?(
         from e in Event,
           where:
             e.tenant_id == ^key.tenant_id and e.repo == ^key.repo and
               e.change_id == ^key.change_id and not is_nil(e.applied_at) and e.routed
       ),
       do: Repo.rollback({:refused, :change_on_chg_route})
  end

  # What of a caller's `opts` reaches `EventEffects.apply_event/3`.
  defp effects_opts(opts), do: Keyword.take(opts, [:escalate])

  # An arrival clears a `stale` flag; a `gap` flag stays until nothing is held.
  defp touch_cursor(%Cursor{} = cursor, held, source, now) do
    attention = if cursor.attention == "gap" and held != [], do: "gap"

    {1, _} =
      Repo.update_all(
        from(c in Cursor, where: c.id == ^cursor.id and c.tenant_id == ^cursor.tenant_id),
        set: [
          applied_seq: cursor.applied_seq,
          last_event_at: now,
          source_id: source.id,
          attention: attention,
          attention_at: if(attention, do: cursor.attention_at),
          updated_at: now
        ]
      )

    :ok
  end

  defp bounded(value) when is_binary(value), do: String.slice(value, 0, 64)
  defp bounded(_value), do: nil
end
