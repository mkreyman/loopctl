defmodule Loopctl.Runners do
  @moduledoc """
  The runner registry and pool of the agent delivery loop (issue #801).

  A **runner** is a dev machine that connects OUTBOUND to loopctl as a Phoenix Channel
  client (`LoopctlWeb.RunnerSocket`). It never joins loopctl's BEAM cluster: a dev
  machine inside the production cluster would reach every process over `:erpc`, so a
  compromised laptop would be a compromised control plane.

  ## Credential

  A runner authenticates with an ordinary `api_keys` row (role `:agent`) bound to one
  machine name by a `Loopctl.Runners.Runner` row. Resolution goes through
  `Auth.verify_api_key/1` — the same function `LoopctlWeb.Plugs.ResolveApiKey` calls —
  so the revocation cache, expiry and tenant suspension apply to the socket exactly as
  they apply to a REST request. A key with no active runner row cannot open the socket.

  Revocation is central (`revoke_runner/3`): it revokes the key and the row in one
  transaction, busts the key cache after commit, and notifies the live channel, which
  disconnects its socket. A key revoked by any other route (`DELETE /api/v1/api_keys/:id`,
  expiry, tenant suspension) is caught by the channel's periodic `authorized?/2` recheck
  and by the same read on every join. A database trigger revokes the runner row with its
  key, so the registry never lists a machine whose credential is gone, and a runner's key
  cannot be rotated through `/api/v1/api_keys`: rotation is revoke plus re-enroll.

  ## Pool

  `Loopctl.Runners.Presence` tracks each joined runner under a TENANT-SCOPED topic,
  `pool_topic/1`, so one tenant's machines are never visible to another. A runner JOINS
  its own topic, `runner:<runner_id>` (the design's single `"runners"` topic would carry
  a broadcast to every tenant's machines). `pool/1` is the read.

  Presence is a liveness hint, never a scheduler: it has no compare-and-set, so capacity
  is reserved in Postgres when dispatch arrives (design §7, `Loopctl.Runners.Capacity`). And it converges only
  across a CLUSTER — on a second, unclustered machine a runner tracked on node A is
  invisible on node B. `Loopctl.ClusterReadiness` warns when that happens.

  ## Dispatch

  `dispatch/3` is the one path by which a dispatch reaches a runner. It validates the
  payload against the contract and refuses a halted tenant, an unauthorized runner and a
  runner without exactly one live socket before anything is sent; the channel repeats the
  halt and single-socket checks right before the push. Every dispatch is recorded in the
  dispatch ledger (`Loopctl.Runners.DispatchLedger`) before it is broadcast, and the runner's
  `dispatch_reply` and trace land there. Recording it takes a capacity slot on the runner and
  counts it against the tenant's admission limit, in the same transaction
  (`Loopctl.Runners.Capacity`). Placement and claiming are the caller's (#803).

  ## Across the cluster

  The production machines form one BEAM cluster (`rel/env.sh.eex`, `DNS_CLUSTER_QUERY`). A
  runner's socket, its channel process and its Presence entry live on whichever node it
  connected to; every other node holds a REPLICA of that entry (Phoenix.Tracker, a CRDT
  replicated over PubSub). Durable state — the runner row, the dispatch ledger, the story's
  `claim_epoch` — lives only in Postgres.

  - **Reaching a runner on another node.** `dispatch/3` may run on either node. It reads the
    local Presence replica, records the dispatch in the ledger, and broadcasts on the
    runner's `dispatch_topic/1`; PubSub delivers that to the channel on whichever node holds
    the socket. Revocation (`revocation_topic/1`) and the socket `disconnect` broadcast
    cross nodes the same way. The node-shutdown notice does not: it is `local_broadcast`.
  - **One socket per runner, cluster-wide.** Both single-socket checks (here and the
    channel's before the push) read Presence, which now includes the other node's
    sockets. Two sockets holding one credential on two nodes each see two entries once
    replication catches up (a Tracker delta, ~1.5 s) and both refuse, where two
    unclustered nodes each saw one and both pushed. A runner that reconnects to the other
    node while its old socket is still draining is briefly `:runner_ambiguous`, until the
    old channel exits.
  - **Netsplit, or a machine killed without its graceful stop.** Tracker goes by heartbeats:
    after 30 s of silence (its default `down_period`) each side drops the other side's
    entries until it hears from it again. A graceful stop is not this case: the draining
    channels exit and their entries leave with them. Inside that window a caller can
    read a stale entry and broadcast a dispatch that never crosses: the ledger row stays
    `sent` with no `pushed_at` (#815), the runner never replies, and unless the claimant
    renews it, the claim's lease expires into the reclaimer. After it, a runner on the far side reads as not connected
    and the dispatch is refused before anything is recorded. A dispatch can also reach two
    sockets of one credential, one per side. Exactly-once is held in Postgres, not in
    Presence: `record_sent/3` writes one row per `dispatch_id`; a reply must present the
    story's CURRENT `claim_epoch` under a row lock, and a differing second reply is
    `:already_replied`; the first trace batch binds one `run_id` to the dispatch and any
    other run is `:run_mismatch`. So a duplicate push can start a second process, but only
    one accepted reply and one trace stream are ever recorded against the claim.
  - **Two nodes racing for the last slot.** Both run the same conditional UPDATE on the
    runner row; Postgres serializes them and exactly one gets a row back. Admission is a
    transaction-scoped advisory lock, so it too is held by Postgres, not by either node.
  - **Retries.** Nothing here retries a broadcast. A dispatch re-sent with the same
    `dispatch_id` finds its ledger row and is pushed again (see `DispatchLedger`), without
    taking a second slot.
  - **Slow links.** Distribution declares a silent peer down after the default
    `net_ticktime` (45-75 s); Presence drops a silent replica after 30 s (above).
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Agent
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.Kinds
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Entry, as: AuditEntry
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.LogValue
  alias Loopctl.Repo
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.Presence
  alias Loopctl.Runners.Runner
  alias Loopctl.Tenants
  alias Loopctl.Tenants.Tenant

  @doc "The tenant-scoped Presence topic a runner is tracked under."
  @spec pool_topic(Ecto.UUID.t()) :: String.t()
  def pool_topic(tenant_id) when is_binary(tenant_id), do: "runners:" <> tenant_id

  @doc "The PubSub topic a runner's live channel listens on for its own revocation."
  @spec revocation_topic(Ecto.UUID.t()) :: String.t()
  def revocation_topic(runner_id) when is_binary(runner_id), do: "runner_revocation:" <> runner_id

  @doc """
  The PubSub topic a runner's live channel listens on for dispatches addressed to it. Per
  runner, like `revocation_topic/1`: the channel turns a message here into a push on its
  own `runner:<runner_id>` topic, and no other process is subscribed.
  """
  @spec dispatch_topic(Ecto.UUID.t()) :: String.t()
  def dispatch_topic(runner_id) when is_binary(runner_id), do: "runner_dispatch:" <> runner_id

  @doc """
  The NODE-LOCAL PubSub topic every runner channel on this node listens on for this node's
  shutdown (`LoopctlWeb.RunnerShutdownNotice`). Broadcast with `local_broadcast`: a stopping
  node must tell only its own runners.
  """
  @spec shutdown_topic() :: String.t()
  def shutdown_topic, do: "runner_shutdown"

  @doc """
  The joined runners of a tenant, as `Phoenix.Presence.list/1` returns them: a map of
  machine name to `%{metas: [meta, ...]}`. More than one meta under a name means more
  than one live socket is using that runner's credential.
  """
  @spec pool(Ecto.UUID.t()) :: map()
  def pool(tenant_id) when is_binary(tenant_id), do: Presence.list(pool_topic(tenant_id))

  @doc """
  Enrolls a machine as a runner: mints its `:agent` API key, gets or creates the
  `runner:<name>` agent its sessions work as, and binds both to `name` in one transaction,
  then records the enrollment on the audit chain. `max_sessions` (1..64, default
  `Runner.default_max_sessions/0`) is the CEILING on how many slots loopctl will ever reserve
  on this machine, and the value it starts at. Since contract 1.13.0 every join re-applies the
  machine's own declaration (`apply_declaration/4`), bounded by this: the held capacity is
  `LEAST(declared, enrolled)`, so a machine may always lower itself below its grant and never
  raise itself above it.

  Which means an operator has two controls and they do different things. To make a machine
  carry FEWER sessions, change its own `control.max_sessions` and reconnect it — the machine
  owns that fact and no operator write is needed. To let it carry MORE than its grant, REVOKE
  it and enrol it again: nothing raises `enrolled_max_sessions` on a live row, deliberately,
  because an endpoint that widens a security bound wants its own change.

  "Enrol it again" is not one call. `runners_active_name_uidx` is partial on
  `revoked_at IS NULL`, so enrolling the same machine name while the current runner is ACTIVE
  is a 422 — `revoke_runner/3` comes first, and that invalidates the credential the machine is
  connected with, so the new token has to reach its token file and the runner has to be
  restarted. Say so wherever this is offered to an operator.

  The agent is GOT or created, never created blindly: `runners_active_name_uidx` is partial on
  `revoked_at IS NULL`, so re-enrolling a revoked machine makes a second runner row for the
  same machine, and both rows must name the one agent — the work is the same machine's either
  way. An agent the tenant already named `runner:<name>` is adopted for the same reason.

  Returns `{:ok, %{runner: runner, raw_key: raw_key}}`. The raw key is returned once
  and never stored.

  ## Options

  - `:actor_lineage` — the enrolling caller's dispatch lineage, for the audit entry.
  """
  @spec enroll_runner(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{runner: Runner.t(), raw_key: String.t()}}
          | {:error, Ecto.Changeset.t() | term()}
  def enroll_runner(tenant_id, attrs, opts \\ []) when is_binary(tenant_id) do
    fields =
      for key <- [:name, :max_sessions],
          value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)),
          not is_nil(value),
          into: %{},
          do: {key, value}

    changeset = Runner.create_changeset(%Runner{tenant_id: tenant_id}, fields)

    if changeset.valid? do
      do_enroll(tenant_id, changeset, opts)
    else
      {:error, changeset}
    end
  end

  defp do_enroll(tenant_id, changeset, opts) do
    name = Ecto.Changeset.get_field(changeset, :name)

    multi =
      Multi.new()
      |> Multi.run(:mint_key, fn _repo, _ ->
        Auth.generate_api_key(%{tenant_id: tenant_id, name: "runner:" <> name, role: :agent})
      end)
      |> Multi.run(:agent, fn _repo, _ -> runner_agent(tenant_id, name) end)
      |> Multi.run(:runner, fn _repo, %{mint_key: {_raw, api_key}, agent: agent} ->
        changeset
        |> Ecto.Changeset.put_change(:api_key_id, api_key.id)
        |> Ecto.Changeset.put_change(:agent_id, agent.id)
        |> AdminRepo.insert()
      end)
      |> Multi.run(:audit, fn _repo, %{runner: runner, mint_key: {_raw, api_key}} ->
        AuditChain.append(tenant_id, %{
          action: "runner_enrolled",
          actor_lineage: Keyword.get(opts, :actor_lineage, []),
          entity_type: "runner",
          entity_id: runner.id,
          payload: %{
            "name" => runner.name,
            "api_key_id" => api_key.id,
            "agent_id" => runner.agent_id,
            "max_sessions" => runner.max_sessions
          }
        })
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{runner: runner, mint_key: {raw_key, _api_key}}} ->
        {:ok, %{runner: runner, raw_key: raw_key}}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  The name of the agent a runner's sessions work as: `runner:<machine name>`.

  THE one declaration on the Elixir side. `20260920100000_add_agent_id_to_runners.exs`
  restates it as SQL because a migration cannot call this, and nothing binds the two — see
  that migration's note.
  """
  @spec agent_name(String.t()) :: String.t()
  def agent_name(name) when is_binary(name), do: "runner:" <> name

  # The agent this machine's sessions work as, in the enrollment transaction.
  #
  # REUSE IS DECIDED BY A PREVIOUS RUNNER ROW, NEVER BY THE NAME ALONE. The obvious shape —
  # insert `ON CONFLICT DO NOTHING`, then read back by name — adopts whatever agent happens to
  # carry that name, and `AgentController`'s `:register` is `exact_role: :agent`, so ANY
  # agent-role key in the tenant can create `runner:minis` before the machine is ever enrolled.
  # No privilege is gained by that (the squatter cannot make the runner do anything), but
  # enrollment would stop owning what a runner's work is attributed to, and a story claimed for
  # this machine would name a row someone else made.
  #
  # So: the only agent adopted is one a PREVIOUS runner row of this tenant and machine name
  # already points at, which is exactly the re-enrollment case the partial active-name index
  # creates (a revoked machine re-enrolled keeps its identity, because it is the same machine).
  # Otherwise a fresh agent is created, and a name already taken by someone else gets a
  # disambiguating suffix rather than failing the enrollment — a squatter must not be able to
  # stop a machine being enrolled either.
  defp runner_agent(tenant_id, name) do
    case previous_runner_agent(tenant_id, name) do
      %Agent{} = agent -> {:ok, agent}
      nil -> create_runner_agent(tenant_id, name)
    end
  end

  defp previous_runner_agent(tenant_id, name) do
    AdminRepo.one(
      from r in Runner,
        join: a in Agent,
        on: a.id == r.agent_id and a.tenant_id == r.tenant_id,
        where: r.tenant_id == ^tenant_id and r.name == ^name and not is_nil(r.agent_id),
        order_by: [desc: r.inserted_at],
        limit: 1,
        select: a
    )
  end

  # `ON CONFLICT DO NOTHING` + `returning` tells insert from conflict without a second read:
  # an empty return means the preferred name is taken by an agent no runner of this name owns.
  # Two concurrent enrollments of one machine both land here (the partial index does not stop a
  # revoked name being re-enrolled twice), and the loser takes the suffixed path rather than
  # failing — they are separate runner rows, so separate agents is a true statement about them.
  defp create_runner_agent(tenant_id, name) do
    case insert_agent(tenant_id, agent_name(name)) do
      {:ok, agent} -> {:ok, agent}
      :taken -> insert_suffixed_agent(tenant_id, name)
    end
  end

  defp insert_suffixed_agent(tenant_id, name) do
    case insert_agent(tenant_id, agent_name(name) <> "-" <> Ecto.UUID.generate()) do
      {:ok, agent} -> {:ok, agent}
      :taken -> {:error, :agent_not_resolved}
    end
  end

  defp insert_agent(tenant_id, agent_name) do
    now = DateTime.utc_now()

    AdminRepo.insert_all(
      Agent,
      [
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          name: agent_name,
          agent_type: :implementer,
          status: :active,
          last_seen_at: now,
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :name],
      returning: [:id]
    )
    |> case do
      {1, [%Agent{id: id}]} -> {:ok, AdminRepo.get!(Agent, id)}
      _conflicted -> :taken
    end
  end

  @doc "Lists a tenant's runners, newest first. Pass `include_revoked: true` for all."
  @spec list_runners(Ecto.UUID.t(), keyword()) :: [Runner.t()]
  def list_runners(tenant_id, opts \\ []) when is_binary(tenant_id) do
    query =
      from r in Runner,
        where: r.tenant_id == ^tenant_id,
        order_by: [desc: r.inserted_at]

    query =
      if Keyword.get(opts, :include_revoked, false),
        do: query,
        else: where(query, [r], is_nil(r.revoked_at))

    AdminRepo.all(query)
  end

  @doc "Gets one runner of a tenant."
  @spec get_runner(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Runner.t()} | {:error, :not_found}
  def get_runner(tenant_id, runner_id) when is_binary(tenant_id) do
    with {:ok, id} <- Ecto.UUID.cast(runner_id),
         %Runner{} = runner <- AdminRepo.get_by(Runner, id: id, tenant_id: tenant_id) do
      {:ok, runner}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Revokes a runner: its row and its API key in one transaction, then busts the key
  cache and tells the live channel, which disconnects its socket.

  The key row and then the runner row are locked inside the transaction — the order the
  api_keys revoke path takes them in, so the two paths cannot deadlock — and concurrent
  revokes serialize and exactly
  one writes `revoked_at` and the `runner_revoked` audit entry. A runner whose row the
  `runners_revoke_with_api_key` trigger already revoked (its key was revoked through
  `/api/v1/api_keys`) still gets its audit entry, once, and its live socket is still told
  — so calling this after a key revoke is never a silent no-op. Idempotent otherwise.
  """
  @spec revoke_runner(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Runner.t()} | {:error, :not_found | term()}
  def revoke_runner(tenant_id, runner_id, opts \\ []) when is_binary(tenant_id) do
    with {:ok, id} <- cast_id(runner_id) do
      do_revoke(tenant_id, id, opts)
    end
  end

  defp cast_id(runner_id) do
    case Ecto.UUID.cast(runner_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp do_revoke(tenant_id, runner_id, opts) do
    now = DateTime.utc_now()

    multi =
      Multi.new()
      |> Multi.run(:locked, fn _repo, _ -> lock_runner(tenant_id, runner_id) end)
      |> Multi.run(:runner, fn _repo, %{locked: runner} -> mark_revoked(runner, now) end)
      |> Multi.run(:revoke_key, fn _repo, %{runner: runner} ->
        revoke_runner_key(tenant_id, runner, now)
      end)
      |> Multi.run(:audit, fn _repo, %{runner: runner} ->
        audit_revocation_once(tenant_id, runner, opts)
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{runner: revoked, revoke_key: key_hashes}} ->
        # AFTER commit: a bust before commit lets a concurrent verify re-cache the
        # still-unrevoked row.
        Auth.invalidate_key_cache_by_hashes(key_hashes)
        Phoenix.PubSub.broadcast(Loopctl.PubSub, revocation_topic(revoked.id), :runner_revoked)
        {:ok, revoked}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  # Locks the api key BEFORE the runner row. `DELETE /api/v1/api_keys/:id` takes them in
  # that order (the key row, then the `runners_revoke_with_api_key` trigger's update of the
  # runner row), so the opposite order here would let the two revoke paths deadlock. The
  # unlocked pre-read only learns `api_key_id`, which never changes after enrollment.
  defp lock_runner(tenant_id, runner_id) do
    with %Runner{api_key_id: key_id} <-
           AdminRepo.get_by(Runner, id: runner_id, tenant_id: tenant_id),
         _key_id <-
           AdminRepo.one(
             from k in ApiKey,
               where: k.id == ^key_id and k.tenant_id == ^tenant_id,
               lock: "FOR UPDATE",
               select: k.id
           ),
         %Runner{} = runner <-
           AdminRepo.one(
             from r in Runner,
               where: r.id == ^runner_id and r.tenant_id == ^tenant_id,
               lock: "FOR UPDATE"
           ) do
      {:ok, runner}
    else
      nil -> {:error, :not_found}
    end
  end

  # An already-revoked row (the api key trigger got there first) passes through, so
  # its audit entry and its live-channel notice still happen.
  defp mark_revoked(%Runner{revoked_at: nil} = runner, now),
    do: AdminRepo.update(Runner.revoke_changeset(runner, now))

  defp mark_revoked(%Runner{} = runner, _now), do: {:ok, runner}

  # Selects the hash back from the revoke itself so the post-commit cache bust needs no
  # second AdminRepo round-trip (the dispatch-revoke pattern). A no-op when the key was
  # revoked first.
  defp revoke_runner_key(tenant_id, runner, now) do
    {_count, key_hashes} =
      from(k in ApiKey,
        where: k.id == ^runner.api_key_id and k.tenant_id == ^tenant_id,
        where: is_nil(k.revoked_at),
        select: k.key_hash
      )
      |> AdminRepo.update_all(set: [revoked_at: now])

    {:ok, key_hashes}
  end

  # Under the row lock, so two callers cannot both find no entry and both write one.
  defp audit_revocation_once(tenant_id, runner, opts) do
    if revocation_audited?(tenant_id, runner.id) do
      {:ok, :already_audited}
    else
      AuditChain.append(tenant_id, %{
        action: "runner_revoked",
        actor_lineage: Keyword.get(opts, :actor_lineage, []),
        entity_type: "runner",
        entity_id: runner.id,
        payload: %{"name" => runner.name, "api_key_id" => runner.api_key_id}
      })
    end
  end

  defp revocation_audited?(tenant_id, runner_id) do
    AdminRepo.exists?(
      from e in AuditEntry,
        where: e.tenant_id == ^tenant_id and e.action == "runner_revoked",
        where: e.entity_type == "runner" and e.entity_id == ^runner_id
    )
  end

  @doc """
  Sends a dispatch to one connected runner. The ONLY path by which a dispatch reaches a
  runner socket. It places nothing and claims no story — the caller names the runner — but
  it does reserve the capacity the dispatch uses. It refuses, in this order:

  1. `{:error, {:invalid, messages}}` — the payload does not match the contract's
     `RunnerDispatch` (`RunnerContract.cast_dispatch/1`). Undeclared keys, at any depth, are
     dropped rather than refused, and never sent.
  2. `{:error, :tenant_halted}` — the tenant's custody operations are halted
     (`Tenants.custody_halted?/1`), read fresh from the database on this call. A dispatch
     starts an implementing session, which is custody progress, the thing a halt suspends.
  3. `{:error, :not_authorized}` — `authorized?/2` is false: no such runner in THIS tenant,
     a malformed id, or a row, key or tenant no longer valid. This is what keeps one tenant
     from addressing another's runner by id.
  4. `{:error, :runner_not_connected}` — the runner is not in the tenant's pool (`pool/1`).
  5. `{:error, :runner_ambiguous}` — more than one live socket holds the runner's
     credential. A dispatch is a prompt executed as the machine's user; with two sockets
     there is no telling which is the enrolled machine, and both would receive it.
  6. `{:error, :kind_not_supported}` — this runner does not do this KIND of work. Since
     contract 1.6.0 the runner's OWN DECLARATION decides (`RunnerJoin.kinds`, read off the
     Presence meta of the sole socket step 5 just proved): a kind outside it is refused, and a
     kind inside it is sent even where an earlier `kind_not_supported` reply is on record.
     Only a runner that declared nothing is decided by that record
     (`DispatchLedger.kind_unsupported?/3`), and then only for the kinds loopctl sent before
     the field existed — a kind it has said nothing about is refused rather than tried.

     The declaration leads because the record is a CACHED NEGATIVE with no expiry and no
     clearing path: without it, a machine that gains a kind by being upgraded stays ineligible
     until a human revokes and re-enrols it. The record is kept as the operator's view of what
     a machine actually refused (`unsupported_kinds/1`) and as the fallback above.

     Either way it is refused BEFORE the ledger, so it takes no slot and passes no admission —
     a machine that does not do the work must not hold capacity for it. Two dispatches of an
     unsupported kind racing can both pass this read, which costs one extra refusal and no
     slot; for an undeclaring runner the memory the first reply writes settles every dispatch
     after it.
  7. `{:error, :dispatch_id_conflict}` — the tenant's ledger already holds this `dispatch_id`
     for a different runner, story, `claim_epoch` or kind.
  8. `{:error, :dispatch_already_replied}` — the runner already accepted or refused this
     `dispatch_id`; sending it again would start a second session.
  9. `{:error, :stale_claim_epoch}` — the dispatch's `claim_epoch` is not the story's current
     one (or the story does not exist): the claim it was built for has already ended.
  10. `{:error, :admission_limit_reached}` — the tenant's runners already hold
      `Capacity.limit/0` slots between them. All of a tenant's sessions run on one Anthropic
      account, and its rate limit is what bites.
  11. `{:error, :runner_at_capacity}` — this runner already holds `max_sessions` slots (or
      was revoked since step 3).
  12. `{:error, :capacity_busy}` — a lock the reservation waits on was not granted within
      `Capacity.lock_timeout_ms/0`. Nothing was recorded or reserved; retry.

  Steps 7-12 run in ONE transaction: the ledger row and its slot commit together or not at
  all, and a re-send of a `dispatch_id` whose row still holds its slot takes no second one.

  Then it writes the dispatch's ledger row as `sent` (`DispatchLedger.record_sent/3`) — or
  finds the one an earlier call with the same `dispatch_id` wrote, so a retry never creates a
  second row — and only then broadcasts on `dispatch_topic/1`. That write runs on the RLS
  `Loopctl.Repo` in a transaction of its own, like the rest of the ledger, so this function
  must not be called from inside a `Repo` transaction (`Repo.with_tenant/2` raises there).
  The runner's channel then pushes the `"dispatch"` event on the runner's own
  `runner:<runner_id>` topic, never a shared or tenant topic.

  `:ok` means handed to the runner's channel, not executed. The channel repeats two checks
  immediately before the push and drops the dispatch when either fails: the halt (a halt
  landing between this read and that one), and that it is the ONLY live socket for the
  runner, by its own Presence ref (a second socket this read did not see yet). A channel
  that died in between receives nothing. Acknowledgement belongs to the dispatch protocol
  (#803), which bumps `claim_epoch` on reclaim.

  Both single-socket checks read Presence, which is eventually consistent ACROSS nodes: two
  sockets on one credential joined to DIFFERENT nodes within Presence's replication interval
  can each see only itself. Exactly-once delivery is therefore not a Presence property; the
  `claim_epoch` fence and the Postgres capacity reservation (#803) are what hold it.
  """
  @spec dispatch(term(), term(), term()) ::
          :ok
          | {:error,
             {:invalid, [String.t()]}
             | :tenant_halted
             | :not_authorized
             | :runner_not_connected
             | :runner_ambiguous
             | :kind_not_supported
             | :dispatch_id_conflict
             | :dispatch_already_replied
             | :stale_claim_epoch
             | :admission_limit_reached
             | :runner_at_capacity
             | :capacity_busy}
  def dispatch(tenant_id, runner_id, payload) do
    case do_dispatch(tenant_id, runner_id, payload) do
      :ok ->
        :ok

      {:error, reason} = refused ->
        log_dispatch_refused(tenant_id, runner_id, payload, reason)
        refused
    end
  end

  # Identifiers only, read defensively: a refused payload may be malformed, so each value is
  # logged only in the shape it claims (`Loopctl.LogValue`).
  defp log_dispatch_refused(tenant_id, runner_id, payload, reason) do
    field = fn key ->
      if is_map(payload),
        do: Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key))
    end

    tenant_id = LogValue.uuid(tenant_id)
    runner_id = LogValue.uuid(runner_id)
    dispatch_id = LogValue.uuid(field.("dispatch_id"))
    story_id = LogValue.uuid(field.("story_id"))
    claim_epoch = LogValue.epoch(field.("claim_epoch"))

    Logger.info(
      "runner dispatch refused: reason=#{inspect(reason)} tenant_id=#{inspect(tenant_id)} " <>
        "runner_id=#{inspect(runner_id)} dispatch_id=#{inspect(dispatch_id)} " <>
        "story_id=#{inspect(story_id)} claim_epoch=#{inspect(claim_epoch)}",
      runner_id: runner_id,
      dispatch_id: dispatch_id,
      story_id: story_id,
      claim_epoch: claim_epoch
    )
  end

  defp do_dispatch(tenant_id, runner_id, payload) do
    with {:ok, dispatch} <- RunnerContract.cast_dispatch(payload),
         {:ok, tenant_id, runner_id} <- cast_ids(tenant_id, runner_id),
         :ok <- not_halted(tenant_id),
         :ok <- runner_authorized(tenant_id, runner_id),
         {:ok, meta} <- single_live_socket(tenant_id, runner_id),
         :ok <- kind_supported(tenant_id, runner_id, meta, dispatch.kind),
         {:ok, _record} <- DispatchLedger.record_sent(tenant_id, runner_id, dispatch) do
      broadcast_dispatch(tenant_id, runner_id, dispatch)
    end
  end

  # The two-element message every deployed node understands. A node of the PREVIOUS release
  # has no clause for a three-element one and crashes on it, dropping the dispatch, so the
  # slot the dispatch carries is NOT put on the wire during a rolling deploy: the channel
  # resolves it from the ledger row when it drops one
  # (`DispatchLedger.release_undelivered_slot/2`), which is also what keeps a drop off a
  # running session's slot. The channel already accepts both shapes, so a later release can
  # move the slot onto the message with no window of its own.
  defp broadcast_dispatch(tenant_id, runner_id, dispatch) do
    case Phoenix.PubSub.broadcast(
           Loopctl.PubSub,
           dispatch_topic(runner_id),
           {:runner_dispatch, dispatch}
         ) do
      :ok ->
        :ok

      # The only failure after the slot is committed. Nothing was handed to any channel, so
      # the slot goes back; a re-send of the same `dispatch_id` takes a fresh one. The release
      # can itself be refused (a lock it could not get), which is an outcome to LOG — matching
      # only `{:ok, _}` here turned an orderly refusal into a MatchError inside the caller.
      {:error, _reason} = error ->
        release_after_failed_broadcast(tenant_id, dispatch.dispatch_id)
        error
    end
  end

  defp release_after_failed_broadcast(tenant_id, dispatch_id) do
    case DispatchLedger.record_drop(tenant_id, dispatch_id) do
      {:ok, :released} ->
        :ok

      other ->
        Logger.warning(
          "runner dispatch slot not released after a failed broadcast: " <>
            "tenant_id=#{tenant_id} dispatch_id=#{dispatch_id} outcome=#{inspect(other)}",
          tenant_id: tenant_id,
          dispatch_id: dispatch_id
        )

        :ok
    end
  end

  @doc """
  Takes one capacity slot on an active runner that has one free: a single conditional
  UPDATE (`Capacity.reserve/2`), in its own transaction. Returns the runner's new
  `in_flight`.

  The primitive, not the dispatch path: a slot taken here belongs to no dispatch, so the
  heal sweep (`heal_capacity/2`) gives it back, and it does not pass admission. Dispatch
  through `dispatch/3`, which ties each slot to its ledger row.
  """
  @spec reserve_slot(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, pos_integer()} | {:error, :runner_at_capacity | :capacity_busy}
  def reserve_slot(tenant_id, runner_id) when is_binary(tenant_id) and is_binary(runner_id) do
    Repo.with_tenant(tenant_id, fn ->
      # Bounded like every other capacity transaction: this one queues behind a heal or a
      # release holding the same runner row.
      Capacity.set_lock_timeout!(Repo)
      Capacity.reserve(Repo, tenant_id, runner_id)
    end)
    |> flatten()
  rescue
    error in Postgrex.Error ->
      if Capacity.retryable?(error),
        do: {:error, :capacity_busy},
        else: reraise(error, __STACKTRACE__)
  end

  @doc """
  Releases the slot GENERATION a dispatch holds, exactly once
  (`DispatchLedger.release_slot/3`), in a transaction of its own. Call it when a dispatch's
  session ends; a replay, or a generation the row no longer holds, returns
  `{:ok, :already_released}` and changes nothing.

  Read the generation from `DispatchLedger.get_record/2` (`slot_generation`) when the
  session starts. A caller that already owns a transaction — a claim release, a stage
  transition — uses `DispatchLedger.release_slot_in/4` instead, so the release commits with
  the transition that decided it rather than after it.

  `{:error, :capacity_busy}` means a lock this needed was not free within
  `Capacity.lock_timeout_ms/0`: nothing was released and the call can be made again after
  `Capacity.busy_retry_ms/0`. The slot stays bounded by the heal sweep meanwhile.
  """
  @spec release_slot(Ecto.UUID.t(), Ecto.UUID.t(), integer()) ::
          {:ok, :released | :already_released}
          | {:error, :unknown_dispatch | :capacity_busy}
  def release_slot(tenant_id, dispatch_id, generation)
      when is_binary(tenant_id) and is_binary(dispatch_id) and is_integer(generation),
      do: DispatchLedger.release_slot(tenant_id, dispatch_id, generation)

  @doc """
  Every kind each of the tenant's runners has REFUSED with `kind_not_supported`, as
  `%{runner_id => [kind]}`. See `Loopctl.Runners.DispatchLedger.unsupported_kinds/1`.

  Since contract 1.6.0 this is the memory step 6 of `dispatch/3` refuses on for an
  UNDECLARING runner only. A runner that declared its kinds on join is decided by the
  declaration, so for that machine this list is the history of what it refused and not a
  statement about the next dispatch.

  **On its own it therefore no longer answers "why does this connected machine get no
  work".** A runner declaring `["triage"]` is refused every `implement` dispatch by the
  declaration, which writes no ledger row, so it appears here with nothing against it. The
  declaration is rendered beside this list on `GET /api/v1/runners/pool` (`kinds`) for
  exactly that reason; read both. It is absent from `GET /api/v1/runners`, which reads
  enrollment rows and cannot see a per-connection value at all.
  """
  @spec unsupported_kinds(Ecto.UUID.t()) :: %{Ecto.UUID.t() => [String.t()]}
  def unsupported_kinds(tenant_id) when is_binary(tenant_id),
    do: DispatchLedger.unsupported_kinds(tenant_id)

  @doc """
  Whether the tenant is under its admission limit right now, for a caller deciding whether
  to CLAIM a story it would then dispatch. A read, not a reservation: two callers can both
  be told `:ok`, and `dispatch/3` is where the limit is enforced under a lock.
  """
  @spec admission(Ecto.UUID.t()) ::
          {:ok, %{in_flight: non_neg_integer(), limit: pos_integer()}}
          | {:error, :admission_limit_reached}
  def admission(tenant_id) when is_binary(tenant_id) do
    {:ok, in_flight} =
      Repo.with_tenant(tenant_id, fn -> Capacity.tenant_in_flight(Repo, tenant_id) end)

    limit = Capacity.limit()

    if in_flight < limit,
      do: {:ok, %{in_flight: in_flight, limit: limit}},
      else: {:error, :admission_limit_reached}
  end

  @doc """
  Releases every reservation of a runner that can no longer be running and recomputes its
  `in_flight` from the rest (`Capacity.heal/3`). Idempotent.
  """
  @spec heal_capacity(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, %{released: non_neg_integer(), in_flight: non_neg_integer() | nil}}
  def heal_capacity(tenant_id, runner_id) when is_binary(tenant_id) and is_binary(runner_id) do
    Repo.with_tenant(tenant_id, fn ->
      Capacity.set_lock_timeout!(Repo)
      Capacity.heal(tenant_id, runner_id)
    end)
    |> flatten()
  end

  defp flatten({:ok, {:ok, _} = ok}), do: ok
  defp flatten({:ok, {:error, _} = error}), do: error
  defp flatten({:error, _} = error), do: error

  @doc """
  The capacity of a tenant's active runners as Postgres holds it — the values every
  reservation is decided against, not the ones runners report in Presence: runner id to
  `%{in_flight, max_sessions, enrolled_max_sessions}`.

  `max_sessions` here is the machine's own declaration CAPPED at `enrolled_max_sessions` and
  then into the column's own range, written at its last join (`apply_declaration/4`). Both are
  returned so an operator can tell a machine held down by its own declaration from one held
  down by the ceiling. `in_flight` is loopctl's count of slots handed out and is never the
  runner's.

  It matches `reported_max_sessions` on the pool once a runner's declaration has been applied
  and that declaration is inside `Runner.max_sessions_range/0` at or below its grant. The
  differences an operator will actually meet, and what each looks like:

  * a declared `0` — the column is 1..64, so `declared_max_sessions/1` holds it as `1` while
    the pool renders the raw `0`. Nothing is dispatched to it either way, because
    `accepting_work?/1` reads the meta's `0` and refuses every path that claims a story before
    it pushes. `max_sessions: 1` against `reported_max_sessions: 0` is the machine saying it
    takes no work, not a drifted row.
  * a declaration ABOVE the grant — held at `enrolled_max_sessions`, which is returned here
    so the pair explains itself.
  * a declaration write that has NOT LANDED — `apply_declaration/4` can fail with
    `:capacity_busy` under contention on the runner row, and the socket retries it on its
    30-second recheck, downward only. Until then the row keeps its older value, which can sit
    on either side of what the machine reports.
  * a socket that joined a node older than contract 1.13.0 and has not reconnected since:
    that join applied no declaration at all.
  """
  @spec capacity(Ecto.UUID.t()) :: %{
          Ecto.UUID.t() => %{
            in_flight: non_neg_integer(),
            max_sessions: pos_integer(),
            enrolled_max_sessions: pos_integer()
          }
        }
  def capacity(tenant_id) when is_binary(tenant_id) do
    from(r in Runner,
      where: r.tenant_id == ^tenant_id and is_nil(r.revoked_at),
      select:
        {r.id,
         %{
           in_flight: r.in_flight,
           max_sessions: r.max_sessions,
           enrolled_max_sessions: r.enrolled_max_sessions
         }}
    )
    |> AdminRepo.all()
    |> Map.new()
  end

  @doc """
  Whether a tenant's custody operations are halted, read FRESH from the database — never
  from a tenant struct loaded earlier. An unknown tenant is not halted; it has no runner
  `authorized?/2` accepts, so a dispatch to it is refused at the next step.
  """
  @spec custody_halted?(Ecto.UUID.t()) :: boolean()
  def custody_halted?(tenant_id) when is_binary(tenant_id) do
    case Tenants.get_tenant(tenant_id) do
      {:ok, tenant} -> Tenants.custody_halted?(tenant)
      {:error, :not_found} -> false
    end
  end

  # A malformed id addresses no runner. Cast before any read, which would raise on it.
  defp cast_ids(tenant_id, runner_id) do
    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         {:ok, runner_id} <- Ecto.UUID.cast(runner_id) do
      {:ok, tenant_id, runner_id}
    else
      :error -> {:error, :not_authorized}
    end
  end

  defp not_halted(tenant_id) do
    if custody_halted?(tenant_id), do: {:error, :tenant_halted}, else: :ok
  end

  defp runner_authorized(tenant_id, runner_id) do
    if authorized?(tenant_id, runner_id), do: :ok, else: {:error, :not_authorized}
  end

  # Before the ledger transaction on purpose: a kind this machine does not do must take no
  # slot and pass no admission on the way to being refused. See step 6 of `dispatch/3`.
  #
  # THE RUNNER'S OWN DECLARATION DECIDES, and the ledger's memory is only the fallback for a
  # runner that made none (contract 1.6.0). The declaration comes off the Presence meta of the
  # SOLE live socket — the one `single_live_socket/2` just proved, so this is the connection
  # the dispatch will be pushed to and not some other socket's claim about the same machine.
  #
  # The order matters and is the whole point. `DispatchLedger.kind_unsupported?/3` is a CACHED
  # NEGATIVE with no expiry and no clearing path: a runner that refused a kind once is
  # ineligible for it for the life of its `runners` row, so a machine that GAINS the kind by
  # being upgraded stays locked out until a human revokes and re-enrols it. Reading the
  # declaration first is what unlocks it — reconnecting is enough — and consulting the ledger
  # afterwards for a declaring runner would put the cache straight back in front of the fact it
  # is a stale copy of.
  #
  # A runner that declares nothing is read as declaring what loopctl sent before the field
  # existed (`Kinds.implied_by_silence/0`) — NOT as declaring everything. Those are the two
  # halves of an undeclaring runner's answer and they are decided separately:
  #
  #   - MEMBERSHIP is answered by the implied set, so a kind loopctl never sent before 1.6.0
  #     is refused rather than being tried on a machine that has said nothing about it. Falling
  #     through to the ledger here would have sent the first triage dispatch to every runner
  #     ever built, since a kind that has never been refused is not recorded as unsupported.
  #   - the LEDGER still governs the kinds in that set, so an older runner's `implement`
  #     behaviour is byte-for-byte what it was: refused once, refused after.
  #
  # The unlock is therefore precise. It reaches a runner that DECLARED the kind, and only that
  # runner, which is exactly the machine whose declaration is newer evidence than the cache.
  @doc """
  Whether a runner would ACCEPT a dispatch of `kind` for `repo` right now, judged from the
  Presence meta of its live socket — the same three facts `dispatch/3` judges, read before
  anything is claimed (#803 §3).

  `dispatch/3` applies `kind` itself and leaves `draining` and `repos` to the runner, which
  refuses them with `draining` and `repo_not_allowed`. That is correct for an operator-driven
  push, where nothing is claimed and a refusal reaches a person. It is NOT enough for
  anything that CLAIMS FIRST — the unattended driver, and `Loopctl.Delivery.Placement`, which
  gates on `accepting_work?/1` for exactly this reason: a placement CLAIMS the story first,
  and `dispatch/3` answers `:ok` the moment it broadcasts, so a refusal the RUNNER makes
  arrives after the claim has committed — the story sits at
  `claimed` with no session until its lease expires, and comes back `queued` with
  `agent_status: :pending`, which no automated path re-contracts.

  So the driver asks this BEFORE placing, and it asks it of the same meta the push would
  reach. `kind_supported/4` is shared with `dispatch/3` rather than reimplemented, because a
  second copy of the declaration-then-ledger rule is exactly how a pre-check and its
  enforcement drift apart.

  `:ok`, or `{:error, :runner_draining | :repo_not_allowed | :kind_not_supported}`.
  """
  @spec accepts?(Ecto.UUID.t(), Ecto.UUID.t(), map(), String.t(), String.t()) ::
          :ok | {:error, :runner_draining | :repo_not_allowed | :kind_not_supported}
  def accepts?(tenant_id, runner_id, meta, kind, repo)
      when is_binary(kind) and is_binary(repo) do
    cond do
      not accepting_work?(meta) -> {:error, :runner_draining}
      not repo_allowed?(meta, repo) -> {:error, :repo_not_allowed}
      true -> kind_supported(tenant_id, runner_id, meta, kind)
    end
  end

  @doc """
  Whether a runner's live meta says it will take ANY work right now — the question that is
  about the machine alone, with no story, kind or repo in it.

  TWO wire spellings, read as ONE statement (#846.4 review finding 8). `draining: true` is
  the declared one. A declared `max_sessions: 0` is the other, and it has to be read here
  because the control plane's column is 1..64: `declared_max_sessions/1` holds a `0` as `1`,
  which is the closest the column can come, and without this predicate that clamp would put
  exactly one dispatch on a machine that said it accepts none. Held at 1 and refused here,
  the machine gets what it asked for and the column stays representable — the same shape as
  `declared_kinds/1`, which stores nothing and reads the meta at the decision.

  This is a judgement about the SOLE live meta a push would reach. It is not the whole of
  `accepts?/5`, which also applies `repos` and `kind`; it is the part `Loopctl.Delivery.Placement`
  can ask without knowing either.
  """
  @spec accepting_work?(map()) :: boolean()
  def accepting_work?(meta) when is_map(meta) do
    Map.get(meta, :draining) != true and Map.get(meta, :max_sessions) != 0
  end

  # A runner that declared NO repos has declared nothing to check — it is the pre-1.x shape
  # and the field is required only from the contract's own version, so an empty or absent
  # list is read as "ask the runner", which is the behaviour every caller had before this
  # function existed. A non-empty list is a statement and is honoured.
  #
  # CASE-INSENSITIVELY, which is the same rule `Loopctl.Intake` applies when it decides
  # whether a webhook's repository is the one a source is bound to. GitHub treats
  # `owner/Repo` and `owner/repo` as one repository, so an exact comparison here would answer
  # "this runner does not have that checkout" for a machine that plainly does — and for the
  # unattended driver that answer is `:no_runner`, the one outcome that logs nothing at all.
  defp repo_allowed?(%{repos: [_ | _] = repos}, repo) do
    wanted = String.downcase(repo)
    Enum.any?(repos, &(is_binary(&1) and String.downcase(&1) == wanted))
  end

  defp repo_allowed?(_meta, _repo), do: true

  defp kind_supported(tenant_id, runner_id, meta, kind) do
    {source, kinds} = declared_kinds(meta)

    cond do
      kind not in kinds ->
        {:error, :kind_not_supported}

      kind in suppressed_kinds(meta) ->
        {:error, :kind_not_supported}

      source == :declared ->
        :ok

      DispatchLedger.kind_unsupported?(tenant_id, runner_id, kind) ->
        {:error, :kind_not_supported}

      true ->
        :ok
    end
  end

  @doc """
  The kinds this CONNECTION has had suppressed because the runner declared one and then
  answered `kind_not_supported` for it (`LoopctlWeb.RunnerChannel`). Held separately from
  the declaration and never folded into it.

  Keeping them apart is not tidiness — they answer different questions for different
  readers. `declared_kinds/1` answers "what did this machine say it does", which the pool
  renders verbatim; this answers "what is loopctl withholding from it right now". Folding a
  suppression into the declaration made the pool report a statement the runner never made: a
  machine that declared `["triage", "implement"]` and refused one `implement` dispatch
  rendered as a triage-only machine, and one that declared `["implement"]` and refused it
  rendered as having declared nothing at all — indistinguishable from a pre-1.6.0 runner.
  """
  @spec suppressed_kinds(map()) :: [String.t()]
  def suppressed_kinds(%{suppressed_kinds: kinds}) when is_list(kinds),
    do: Enum.filter(kinds, &is_binary/1)

  def suppressed_kinds(meta) when is_map(meta), do: []

  @doc """
  The dispatch kinds a runner's join meta declares, tagged with where they came from:
  `{:declared, kinds}` when the runner sent `RunnerJoin.kinds` (contract 1.6.0), and
  `{:implied, kinds}` when it sent none and is therefore read as declaring what loopctl sent
  before the field existed (`RunnerContract.Kinds.implied_by_silence/0`).

  The tag is the half that matters, and it is not cosmetic: `dispatch/3` reads the ledger's
  `kind_not_supported` memory for an `:implied` runner and NOT for a `:declared` one. A meta
  that fell back to `:implied` by accident would put a runner that has just declared a kind
  back behind the cached negative it declared its way out of, which is the whole change.

  A declaration is believed only in the shape `RunnerContract.cast_join/1` produces — a
  non-empty list of binaries. The cast has already refused anything else, so this guard is
  against a meta built some other way (a test, a future writer) reading as a declaration it
  is not.

  ## An unknown kind needs no filtering, and is returned VERBATIM

  `RunnerJoin.kinds` carries no `enum`, on purpose: a runner upgraded ahead of loopctl —
  same MAJOR, so the join is admitted — may declare a kind this server has never heard of,
  and refusing the payload would drop that machine out of the fleet over a field that exists
  to ADD capability. Dropping the `enum` is the whole of that fix.

  This function then returns what the runner SAID, unfiltered. An intersection against
  `Kinds.all/0` was tried and removed: `kind_supported/4` asks `kind in kinds`, so an
  unknown entry can never match a kind loopctl is able to send and the filter changed no
  decision — proved inert by mutation, the check stayed green with it gone. What it did
  change was the pool, where it hid half of what a machine declared, which is the same
  defect as folding a suppression into the declaration. Duplicates are ignored for the same
  reason: membership does not care, so nothing has to remove them.

  So a declaration of ONLY unknown kinds is `{:declared, [those]}` and every dispatch this
  server can send is refused against it — the right answer, reached without a special case.
  It is NOT read as silence: the runner did speak, and naming nothing loopctl knows is a
  statement, not an absence. That machine is sent nothing until loopctl learns the kind, and
  the pool shows exactly what it said.
  """
  @spec declared_kinds(map()) :: {:declared | :implied, [String.t()]}
  def declared_kinds(%{kinds: [_ | _] = kinds}) do
    if Enum.all?(kinds, &is_binary/1),
      do: {:declared, kinds},
      else: {:implied, Kinds.implied_by_silence()}
  end

  def declared_kinds(meta) when is_map(meta), do: {:implied, Kinds.implied_by_silence()}

  @doc """
  The branch-name prefixes a runner's join meta declares (`RunnerJoin.branch_prefixes`,
  contract 1.14.0), or `[]` when it declared none.

  READ LIVE AT THE DECISION AND STORED NOWHERE, which is the same shape as `declared_kinds/1`
  and is the point rather than an implementation detail. A runner declares a capability and
  loopctl DERIVES from the declaration; it never keeps an independent copy that can drift.
  Capacity is the one field that could not be done this way — a reservation is a conditional
  UPDATE under a row lock and a CRDT replica cannot hand out the last slot to exactly one
  caller — and `apply_declaration/4` says so. A branch NAME needs no lock, so it takes the
  purer form: `Loopctl.Delivery.Placement` reads the meta of the sole live socket the push
  would reach and passes the list to `Loopctl.Delivery.DispatchPayload.fill/3`.

  Two things follow from there being no stored copy, and both are answers rather than
  caveats. A reconnect carrying a different set simply decides differently from then on,
  with nothing to reconcile and no migration to write. And a STALE Presence entry cannot be
  read as a declaration on its own: the caller resolves the SOLE live meta, so while a
  reconnecting runner has two entries visible the placement path has no single meta at all —
  the same judgement `single_live_socket/2` makes for every other decision about that machine.

  `[]` is returned for silence, for an empty array, and for a list carrying a non-binary —
  every one of which means "this machine stated no usable constraint", which is exactly
  today's behaviour. The declaration is otherwise returned VERBATIM, for the reason
  `declared_kinds/1` gives at length: filtering here would hide half of what a machine
  declared from the pool while changing no decision. A prefix that cannot produce a valid
  branch is settled at the derivation, where the composed name is the thing that can actually
  be judged, and it refuses the placement rather than being silently dropped — dropped, the
  next prefix would be used and the runner would refuse the dispatch it produced.
  """
  @spec declared_branch_prefixes(map()) :: [String.t()]
  def declared_branch_prefixes(%{branch_prefixes: [_ | _] = prefixes}) do
    if Enum.all?(prefixes, &is_binary/1), do: prefixes, else: []
  end

  def declared_branch_prefixes(meta) when is_map(meta), do: []

  @doc """
  The capacity a join declared, as a value `runners.max_sessions` can hold.

  `{:ok, n}` when the declaration is already inside `Runner.max_sessions_range/0`,
  `{:clamped, n, declared}` when it had to be moved into it, and `:undeclared` when the meta
  carries no integer under `:max_sessions` at all.

  ## Why this is CLAMPED rather than trusted or refused

  `max_sessions` is a value a MACHINE supplies and loopctl then reserves against, so it is an
  input. `RunnerJoin` already bounds it 0..64 and `cast_join/1` refuses a join outside that,
  which is why 9999 never reaches here; the clamp is what holds when the meta was built
  without passing that cast, and it is the only thing standing between the wire and a
  `runners_max_sessions_range` violation.

  **Zero is the case that is really in range on the wire and NOT in range in the column**,
  and it is clamped UP to one HERE while being honoured in full at the decision. The column is
  1..64, so one is the closest it can come to what the machine said; ignoring the zero would
  be worse, because it leaves whatever the row held — a machine declaring `0` against an
  enrolled `2` would keep the `2`, the exact over-reservation this path exists to end.

  What makes the clamp honest rather than a one-dispatch lie is that `accepting_work?/1` reads
  the declared `0` off the meta and refuses, on every path that claims a story before it
  pushes (#846.4 review finding 8). So `0` and `draining` are two spellings of one statement
  and both are actionable; the column holds `1` and nothing is sent to it.

  **A join is never refused over this.** Same reasoning as `declared_kinds/1`: a machine that
  cannot get a socket is out of the fleet, and a capacity loopctl can clamp is not worth that.
  """
  @spec declared_max_sessions(map()) ::
          {:ok, pos_integer()} | {:clamped, pos_integer(), integer()} | :undeclared
  def declared_max_sessions(%{max_sessions: declared}) when is_integer(declared) do
    range = Runner.max_sessions_range()
    held = declared |> max(range.first) |> min(range.last)

    if held == declared, do: {:ok, held}, else: {:clamped, held, declared}
  end

  def declared_max_sessions(meta) when is_map(meta), do: :undeclared

  @doc """
  Applies what a joining runner DECLARED about itself to the row loopctl decides from.

  Today that is capacity alone: `runners.max_sessions` is set to the machine's declared
  `max_sessions` (`Capacity.apply_declared/5`), clamped into the column's range by
  `declared_max_sessions/1`. Returns `:ok` whatever it found — an unchanged capacity, a
  runner revoked since the socket opened, and a meta with no declaration all mean there is
  nothing to write.

  ## Why the machine's number wins, and not the operator's

  The held row used to be written once, at enrollment, and never again, so a machine enrolled
  at two and configured for one was dispatched two sessions for ever: `minis` rejoined twice
  on 2026-09-16 carrying `max_sessions: 1` and `GET /api/v1/runners/pool` went on reporting a
  held `2` against a reported `1`. That is not a stale row, it is a row with no path from the
  declaration, which is why this runs on every join rather than in a backfill.

  Three reasons the declaration is the side to believe:

  1. **The runner owns the fact.** Capacity is a statement about a machine's ability to run
     sessions and the machine is the only thing that knows it. A second copy in the control
     plane drifts by construction, because nothing updates it.
  2. **The drift is asymmetric.** Holding two against a real one places a dispatch the
     machine refuses `at_capacity`; the refusal costs the claim and parks the story
     (`Loopctl.Delivery.Placement`). Holding one against a real two only under-uses the
     machine for as long as it takes to reconnect. When a disagreement can only be wrong
     in one direction, believe the side whose error is cheaper.
  3. **The declaration already arrives on every join** (`RunnerJoin` requires
     `max_sessions`), so this costs one conditional UPDATE and no new message.

  This is the THIRD field to move this way, not a capacity special case: `kinds` moved at
  contract 1.6.0, `branch_prefixes` at 1.14.0 (story 846.2), and capacity is this. The shape
  they share is that a runner DECLARES a capability and loopctl DERIVES from the declaration
  instead of keeping an independent copy — `declared_kinds/1` and
  `declared_branch_prefixes/1` store nothing at all and read the meta at the decision.

  **CAPACITY IS THE ONLY ONE THAT NEEDED THIS FUNCTION, and the reason is the test for a
  fourth.** A reservation is a conditional UPDATE against a column, and a CRDT replica cannot
  hand out the last slot to exactly one caller, so the fact has to be decided under a row
  lock and therefore has to be IN a row. Nothing else here has that property: a kind is a
  membership test and a branch prefix is a string concatenation, both decided in the process
  that already holds the meta. So this is the same rule with the one mechanism it allows when
  a fact must be decided under a row lock — copy it in at the moment the machine states it,
  and nowhere else. A field that does NOT need a lock belongs in `declared_*`, without a
  migration and without a second copy to reconcile.

  ## Where it runs, and what it is NOT on

  In `LoopctlWeb.RunnerChannel`'s `:after_join`, BEFORE `Presence.track/4` — which is the last
  instant at which THIS socket cannot yet be dispatched to, since `dispatch/3` needs a live
  socket in the pool.

  That is a bound, not a guarantee, and the difference matters because it is the sentence a
  later change would lean on. It holds absolutely only when the joining socket is the runner's
  ONLY one. On a RECONNECT the previous socket's Presence entry can still be visible — a
  silent node's entries linger up to 30 seconds (see the moduledoc) — so
  `single_live_socket/2` can resolve to the STALE meta and `dispatch/3` can reserve against
  the old `max_sessions` in the window between this join and this write's commit. That window
  is milliseconds, and what is on the other side of it is now bounded too: a slot taken
  against the old number is clamped by the write (`Capacity.apply_declared/5`) and given back
  by a RECOUNT rather than a decrement (`Capacity.give_back/3`), so an over-count converges
  instead of compounding. Running this AFTER `Presence.track/4` would widen the same window
  from milliseconds to the whole of the join, which is why the order stays.

  It appends NOTHING to the audit chain, deliberately. Enrollment is on the chain because it
  mints a credential and binds it to a machine — custody evidence. A slot count decides
  nothing about who implemented, reported or verified anything; it arrives on every reconnect
  (up to `@max_joins` a minute per runner); and the tenant's chain head is the row every
  writer in the tenant contends on, which the lock order says to hold for the shortest
  possible time. A capacity move is instead LOGGED here and visible on
  `GET /api/v1/runners/pool` as both numbers at once. Revisit if a capacity a machine
  declared is ever cited in a custody dispute.

  ## What a FAILED write returns, and who retries it

  `:ok` means the declaration is SETTLED — applied, already equal, nothing declared, or a
  runner that is gone. `{:error, reason}` means the write was attempted and did not land, and
  it is returned rather than swallowed so the caller can try again: the realistic failure is
  `:capacity_busy`, the `runners` row's 5-second `lock_timeout` running out against the row
  every dispatch in the tenant contends on — which is exactly the load under which
  over-dispatching hurts most. Nothing else reconciles it: `Capacity.heal/3` recomputes
  `in_flight` and never touches `max_sessions`, so a swallowed failure left the machine
  dispatchable against the stale larger number until it happened to reconnect
  (#846.4 review finding 5). `LoopctlWeb.RunnerChannel` re-arms it on its `:recheck` timer,
  passing `only_lower: true`. A retry re-applies a declaration its OWN connection carried,
  which may by then be the older of two, and `Capacity.apply_declared/5` sets out why the
  answer to not knowing is to allow the write only in the direction that is cheap when it is
  wrong. The channel also skips the retry while the runner has more than one live socket,
  which is the same judgement made where it is cheap to make.
  """
  @spec apply_declaration(Ecto.UUID.t(), Runner.t(), map(), keyword()) :: :ok | {:error, term()}
  def apply_declaration(tenant_id, %Runner{} = runner, meta, opts \\ [])
      when is_binary(tenant_id) and is_map(meta) and is_list(opts) do
    case declared_max_sessions(meta) do
      :undeclared ->
        :ok

      {:ok, declared} ->
        write_declared_capacity(tenant_id, runner, declared, opts)

      {:clamped, declared, raw} ->
        Logger.warning(
          "runner #{runner.name} declared max_sessions #{raw}, outside the " <>
            "#{inspect(Runner.max_sessions_range())} loopctl can hold; using #{declared}. " <>
            "A machine that wants no work declares draining or max_sessions 0, either of " <>
            "which loopctl refuses a PLACEMENT against; a direct operator push is still " <>
            "delivered and the runner refuses it itself."
        )

        write_declared_capacity(tenant_id, runner, declared, opts)
    end
  end

  defp write_declared_capacity(tenant_id, runner, declared, opts) do
    case apply_declared_capacity(tenant_id, runner.id, declared, opts) do
      :unchanged ->
        :ok

      {:ok, %{max_sessions: max_sessions, in_flight: in_flight}} ->
        Logger.info(
          "runner #{runner.name} capacity now #{max_sessions} (declared on join); " <>
            "in_flight #{in_flight}"
        )

        :ok

      {:error, reason} ->
        # The runner keeps the capacity the row already held, which is the behaviour that
        # existed before this path — never a refused join, and never a silent one. RETURNED
        # rather than swallowed as `:ok`, so the channel re-arms it: until it lands, the
        # machine is dispatchable against the stale number and nothing else reconciles that.
        Logger.error(
          "could not apply runner #{runner.name}'s declared max_sessions #{declared} " <>
            "(#{describe_failure(reason)}); loopctl goes on reserving against the capacity " <>
            "it holds and will retry on this socket's next recheck"
        )

        {:error, reason}
    end
  end

  defp describe_failure(%_{} = exception) when is_exception(exception),
    do: "#{inspect(exception.__struct__)}: #{Exception.message(exception)}"

  defp describe_failure(reason), do: inspect(reason)

  defp apply_declared_capacity(tenant_id, runner_id, declared, opts) do
    Repo.with_tenant(tenant_id, fn ->
      # Bounded like every other capacity transaction: this one queues behind a reserve, a
      # release or a heal holding the same runner row, and the process it runs in is the one
      # holding the machine's socket.
      Capacity.set_lock_timeout!(Repo)
      Capacity.apply_declared(Repo, tenant_id, runner_id, declared, opts)
    end)
    |> case do
      # NOT `flatten/1`: this call's success is `:unchanged` as often as it is `{:ok, held}`,
      # and a bare atom inside the transaction tuple matches none of its clauses.
      {:ok, :unchanged} -> :unchanged
      {:ok, {:ok, held}} -> {:ok, held}
      {:error, reason} -> {:error, reason}
    end

    # EVERY DATABASE FAILURE IS CAUGHT HERE, and none is re-raised (#846.4 review finding 4).
    # This call runs inside `handle_info(:after_join, ...)`, so an exception escaping it kills
    # the channel and takes the runner OUT OF THE POOL — and the runner reconnects, which under
    # a database blip is a crash/reconnect loop across the whole fleet at once. Before capacity
    # followed the declaration, `:after_join` touched no database and could not do that.
    #
    # Rescuing `Postgrex.Error` alone was not enough in either direction. A pool-checkout
    # timeout or a dropped connection arrives as `DBConnection.ConnectionError`, which is a
    # different struct and was not caught at all; and a database RESTART arrives as a
    # `Postgrex.Error` that `retryable?/1` says no to, so it was caught and then re-raised. Both
    # are availability, both have the same right answer, and it is the one this path already
    # documents: keep the capacity the row holds, log it, try again on the next recheck. The
    # signal a re-raise would have carried is the `Logger.error` above, which now names the
    # exception.
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      if Capacity.retryable?(error),
        do: {:error, :capacity_busy},
        else: {:error, error}
  end

  @doc """
  The Presence metas of every live socket holding `runner_id`'s credential in the tenant's
  pool, each carrying its `:phx_ref`. The pool is keyed by machine name; the id is on each
  meta. Read from the TENANT's pool only, so a runner connected under another tenant is
  never found here.
  """
  @spec live_metas(Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  def live_metas(tenant_id, runner_id) when is_binary(tenant_id) and is_binary(runner_id) do
    for {_name, %{metas: metas}} <- pool(tenant_id),
        %{runner_id: ^runner_id} = meta <- metas,
        do: meta
  end

  defp single_live_socket(tenant_id, runner_id) do
    case live_metas(tenant_id, runner_id) do
      [] -> {:error, :runner_not_connected}
      [one] -> {:ok, one}
      [_ | _] -> {:error, :runner_ambiguous}
    end
  end

  @doc "Whether `api_key_id` is the credential of a runner (active or revoked)."
  @spec runner_key?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def runner_key?(tenant_id, api_key_id) when is_binary(tenant_id) and is_binary(api_key_id) do
    AdminRepo.exists?(
      from r in Runner, where: r.tenant_id == ^tenant_id and r.api_key_id == ^api_key_id
    )
  end

  @doc """
  Authenticates a runner credential presented on the runner socket.

  Returns `{:ok, %{runner: runner, api_key: api_key}}`, or `{:error, reason}` where
  reason is one of `:invalid_token`, `:tenant_inactive`, `:not_a_runner` or
  `:runner_revoked`. The reason is for the server log; the socket answers every
  failure identically.
  """
  @spec authenticate(term()) ::
          {:ok, %{runner: Runner.t(), api_key: ApiKey.t()}}
          | {:error, :invalid_token | :tenant_inactive | :not_a_runner | :runner_revoked}
  def authenticate(raw_token) do
    case authenticate_identified(raw_token) do
      {:ok, auth} -> {:ok, auth}
      {:error, reason, _identity} -> {:error, reason}
    end
  end

  @doc """
  `authenticate/1`, with what WAS resolved on a refusal (issue #815): the key's `api_key_id`,
  `tenant_id` and `runner_id` where resolution got that far, `nil` otherwise. For the
  socket's refusal log only; never the token.
  """
  @spec authenticate_identified(term()) ::
          {:ok, %{runner: Runner.t(), api_key: ApiKey.t()}}
          | {:error, :invalid_token | :tenant_inactive | :not_a_runner | :runner_revoked,
             %{
               api_key_id: Ecto.UUID.t() | nil,
               tenant_id: Ecto.UUID.t() | nil,
               runner_id: Ecto.UUID.t() | nil
             }}
  def authenticate_identified(raw_token) when is_binary(raw_token) and raw_token != "" do
    with {:ok, api_key} <- verify(raw_token),
         :ok <- tenant_active(api_key),
         {:ok, runner} <- runner_for_key(api_key) do
      {:ok, %{runner: runner, api_key: api_key}}
    end
  end

  def authenticate_identified(_raw_token), do: {:error, :invalid_token, identity(nil, nil)}

  defp identity(api_key, runner) do
    %{
      api_key_id: api_key && api_key.id,
      tenant_id: api_key && api_key.tenant_id,
      runner_id: runner && runner.id
    }
  end

  defp verify(raw_token) do
    case Auth.verify_api_key(raw_token) do
      {:ok, %ApiKey{tenant_id: tenant_id, role: :agent} = api_key} when is_binary(tenant_id) ->
        {:ok, api_key}

      {:ok, %ApiKey{} = api_key} ->
        {:error, :not_a_runner, identity(api_key, nil)}

      {:error, _} ->
        {:error, :invalid_token, identity(nil, nil)}
    end
  end

  defp tenant_active(%ApiKey{tenant: %Tenant{status: :active}}), do: :ok
  defp tenant_active(api_key), do: {:error, :tenant_inactive, identity(api_key, nil)}

  defp runner_for_key(%ApiKey{id: key_id, tenant_id: tenant_id} = api_key) do
    case AdminRepo.get_by(Runner, api_key_id: key_id, tenant_id: tenant_id) do
      nil -> {:error, :not_a_runner, identity(api_key, nil)}
      %Runner{revoked_at: nil} = runner -> {:ok, runner}
      %Runner{} = runner -> {:error, :runner_revoked, identity(api_key, runner)}
    end
  end

  @doc "This node's name, as a string, for runner presence metas and logs (issue #815)."
  @spec node_name() :: String.t()
  def node_name, do: Atom.to_string(node())

  @doc """
  The Fly Machine this node runs on (`FLY_MACHINE_ID`, injected by Fly), or nil off Fly.
  Off Fly every node is named `loopctl@127.0.0.1` (`rel/env.sh.eex`), so the machine id is
  what tells a runner's connection apart there; on Fly the node name already carries the
  machine's address and release, and the machine id is the name an operator acts on.
  """
  @spec machine_id() :: String.t() | nil
  def machine_id do
    case System.get_env("FLY_MACHINE_ID") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  @doc """
  Whether a connected runner is still allowed to be connected: its row is not revoked,
  its key is neither revoked nor expired, and its tenant is active. One query.

  This is the backstop for every revocation that does not go through `revoke_runner/3`.
  """
  @spec authorized?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def authorized?(tenant_id, runner_id) when is_binary(tenant_id) and is_binary(runner_id) do
    now = DateTime.utc_now()

    query =
      from r in Runner,
        join: k in ApiKey,
        on: k.id == r.api_key_id and k.tenant_id == r.tenant_id,
        join: t in Tenant,
        on: t.id == r.tenant_id,
        where: r.id == ^runner_id and r.tenant_id == ^tenant_id,
        where: is_nil(r.revoked_at) and is_nil(k.revoked_at),
        where: is_nil(k.expires_at) or k.expires_at > ^now,
        where: t.status == :active,
        select: true

    AdminRepo.exists?(query)
  end
end
