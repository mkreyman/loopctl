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
  must be reserved in Postgres when dispatch arrives (design §7). And it converges only
  across a CLUSTER — on a second, unclustered machine a runner tracked on node A is
  invisible on node B. `Loopctl.ClusterReadiness` warns when that happens.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Entry, as: AuditEntry
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Runners.Presence
  alias Loopctl.Runners.Runner
  alias Loopctl.Tenants.Tenant

  @doc "The tenant-scoped Presence topic a runner is tracked under."
  @spec pool_topic(Ecto.UUID.t()) :: String.t()
  def pool_topic(tenant_id) when is_binary(tenant_id), do: "runners:" <> tenant_id

  @doc "The PubSub topic a runner's live channel listens on for its own revocation."
  @spec revocation_topic(Ecto.UUID.t()) :: String.t()
  def revocation_topic(runner_id) when is_binary(runner_id), do: "runner_revocation:" <> runner_id

  @doc """
  The joined runners of a tenant, as `Phoenix.Presence.list/1` returns them: a map of
  machine name to `%{metas: [meta, ...]}`. More than one meta under a name means more
  than one live socket is using that runner's credential.
  """
  @spec pool(Ecto.UUID.t()) :: map()
  def pool(tenant_id) when is_binary(tenant_id), do: Presence.list(pool_topic(tenant_id))

  @doc """
  Enrolls a machine as a runner: mints its `:agent` API key and binds it to `name` in
  one transaction, and records the enrollment on the audit chain.

  Returns `{:ok, %{runner: runner, raw_key: raw_key}}`. The raw key is returned once
  and never stored.

  ## Options

  - `:actor_lineage` — the enrolling caller's dispatch lineage, for the audit entry.
  """
  @spec enroll_runner(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{runner: Runner.t(), raw_key: String.t()}}
          | {:error, Ecto.Changeset.t() | term()}
  def enroll_runner(tenant_id, attrs, opts \\ []) when is_binary(tenant_id) do
    name = Map.get(attrs, :name) || Map.get(attrs, "name")
    changeset = Runner.create_changeset(%Runner{tenant_id: tenant_id}, %{name: name})

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
      |> Multi.run(:runner, fn _repo, %{mint_key: {_raw, api_key}} ->
        changeset
        |> Ecto.Changeset.put_change(:api_key_id, api_key.id)
        |> AdminRepo.insert()
      end)
      |> Multi.run(:audit, fn _repo, %{runner: runner, mint_key: {_raw, api_key}} ->
        AuditChain.append(tenant_id, %{
          action: "runner_enrolled",
          actor_lineage: Keyword.get(opts, :actor_lineage, []),
          entity_type: "runner",
          entity_id: runner.id,
          payload: %{"name" => runner.name, "api_key_id" => api_key.id}
        })
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{runner: runner, mint_key: {raw_key, _api_key}}} ->
        {:ok, %{runner: runner, raw_key: raw_key}}

      {:error, _step, reason, _} ->
        {:error, reason}
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
  def authenticate(raw_token) when is_binary(raw_token) and raw_token != "" do
    with {:ok, api_key} <- verify(raw_token),
         :ok <- tenant_active(api_key.tenant),
         {:ok, runner} <- runner_for_key(api_key) do
      {:ok, %{runner: runner, api_key: api_key}}
    end
  end

  def authenticate(_raw_token), do: {:error, :invalid_token}

  defp verify(raw_token) do
    case Auth.verify_api_key(raw_token) do
      {:ok, %ApiKey{tenant_id: tenant_id, role: :agent} = api_key} when is_binary(tenant_id) ->
        {:ok, api_key}

      {:ok, %ApiKey{}} ->
        {:error, :not_a_runner}

      {:error, _} ->
        {:error, :invalid_token}
    end
  end

  defp tenant_active(%Tenant{status: :active}), do: :ok
  defp tenant_active(_tenant), do: {:error, :tenant_inactive}

  defp runner_for_key(%ApiKey{id: key_id, tenant_id: tenant_id}) do
    case AdminRepo.get_by(Runner, api_key_id: key_id, tenant_id: tenant_id) do
      nil -> {:error, :not_a_runner}
      %Runner{revoked_at: nil} = runner -> {:ok, runner}
      %Runner{} -> {:error, :runner_revoked}
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
