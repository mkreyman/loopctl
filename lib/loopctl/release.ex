defmodule Loopctl.Release do
  @moduledoc """
  Release tasks for production, run WITHOUT mix (which does not exist in a
  compiled release) via the release `eval` command:

      bin/loopctl eval "Loopctl.Release.migrate()"
      bin/loopctl eval "Loopctl.Release.custody_signed_profile(:status)"

  Uses `Loopctl.AdminRepo` (BYPASSRLS role) because RLS policy
  migrations require elevated privileges that the regular app role
  does not have.
  """

  import Ecto.Query, only: [from: 2]

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Custody.SignedProfilePolicy
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.SystemConfig
  alias Loopctl.Tenants.Tenant

  @app :loopctl

  @doc """
  Runs all pending Ecto migrations using AdminRepo.

  AdminRepo connects with the BYPASSRLS role, which is required
  because RLS policy DDL statements fail under a restricted role.
  """
  def migrate do
    load_app()

    # Run migrations from priv/repo/migrations/ using AdminRepo.
    # AdminRepo has BYPASSRLS privilege needed for RLS policy DDL.
    # We specify the path explicitly because AdminRepo defaults to
    # priv/admin_repo/migrations/ but all migrations live in priv/repo/.
    {:ok, _, _} =
      Ecto.Migrator.with_repo(Loopctl.AdminRepo, fn repo ->
        path = Ecto.Migrator.migrations_path(Loopctl.Repo)
        Ecto.Migrator.run(repo, path, :up, all: true)
      end)
  end

  @doc """
  Rolls back the last migration using AdminRepo.
  """
  def rollback(version) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Loopctl.AdminRepo, fn repo ->
        path = Ecto.Migrator.migrations_path(Loopctl.Repo)
        Ecto.Migrator.run(repo, path, :down, to: version)
      end)
  end

  @doc """
  Reads or flips the LCP-1 §9 signed-custody-profile DEPLOYMENT switch — the
  `SystemConfig` integer `custody_signed_profile_enforcement` (0 = bearer, the
  default; 1 = signed). This is the prod-safe analog of a mix task (mix does not
  exist in a release); run it with the release `eval` command:

      bin/loopctl eval "Loopctl.Release.custody_signed_profile(:status)"
      bin/loopctl eval "Loopctl.Release.custody_signed_profile(:enable)"
      bin/loopctl eval "Loopctl.Release.custody_signed_profile(:disable)"

  ## What flipping it CAN and CANNOT do (read before enabling)

  `signed` requires an ENROLLED agent (one whose dispatch carries a signing key)
  to cryptographically sign its custody claims. It is enforced by
  `LoopctlWeb.Plugs.RequireSignedClaim`, mounted on the three single-item custody
  gates — `report`, `review-complete`, `verify` — AND, with `bulk: true`, on the
  SET-BASED custody actions `verify_all` (story verification) and the bulk
  `verify` / `mark_complete` (bulk operations). It therefore:

    * does **NOT** gate the Knowledge Wiki, agent memory, the context retriever,
      or ANY read path — **KB access cannot be lost by enabling this**;
    * does **NOT** gate authentication, signup, or tenant access;
    * is **enrolled-only / gradual** on the three single-item gates: a caller
      whose AGENT has NO enrolled signing key ANYWHERE is waived (proceeds), so
      with zero enrolled agents the switch is INERT — it changes nothing
      observable until you register a tenant owner key and enroll an agent.
      Mind the mixed case though: the waiver is keyed on the AGENT, not the
      dispatch. Once an agent enrolls ONE dispatch, its OTHER (bearer, unsigned)
      dispatches are HARD-REFUSED — `agent_enrollment_required` (403), NOT waived
      — because a bearer dispatch may not act unsigned in an already-enrolled
      agent's name. So enabling `signed` can start failing an agent's older
      bearer dispatch the moment it enrolls a newer one. `:status` reports the
      enrolled count so you flip with eyes open;
    * but on the aggregate paths (`verify_all`, bulk `verify` / `mark_complete`)
      `signed` does NOT waive-then-sign — it HARD-REFUSES an enrolled caller with
      `bulk_signature_unsupported` (401), because a per-story claim signature
      cannot cover an unbounded set. **Enabling `signed` will break bulk
      verify-all and bulk mark-complete for enrolled agents**; those agents must
      fall back to verifying each story individually through the signed
      single-story gate.

  Fully reversible (`:disable`). `:enable`/`:disable` write the DB value; the
  status this command prints reflects the STORED DB row — NOT what any serving
  node is enforcing at this instant. Serving nodes refresh their node-local
  (`:persistent_term`) cache from the DB asynchronously: once at boot AND via the
  `SystemConfigRefreshWorker` Oban cron. That cron enqueues ONE job per tick
  CLUSTER-WIDE (executed by a single node), so on a MULTI-NODE deployment a given
  node's adoption latency is NOT bounded to ~60s — it can lag many ticks, and an
  emergency `:disable` rollback may leave some nodes enforcing `signed` (401'ing
  enrolled agents) for an unbounded window. The ~60s guarantee holds only on a
  SINGLE-NODE deployment. To confirm a specific node has actually adopted the
  flip, read THAT node's `GET /.well-known/loopctl` `custody_profile` — each node
  serves its own node-local value. The `eval` node's own cache is irrelevant (it
  exits immediately); the DB row is the source of truth.
  """
  @spec custody_signed_profile(:status | :enable | :disable) :: :ok | {:error, term()}
  def custody_signed_profile(action \\ :status)

  def custody_signed_profile(:status), do: with_admin_repo(&print_custody_profile_status/0)
  def custody_signed_profile(:enable), do: with_admin_repo(fn -> set_custody_profile(1) end)
  def custody_signed_profile(:disable), do: with_admin_repo(fn -> set_custody_profile(0) end)

  def custody_signed_profile(other) do
    IO.puts("Unknown action #{inspect(other)} — use :status, :enable, or :disable.")
    {:error, :unknown_action}
  end

  # --- signed-profile helpers (public @doc false so the release-command logic is
  # unit-testable against the sandbox without re-entering with_admin_repo/1) ---

  @doc false
  def set_custody_profile(value) when value in [0, 1] do
    # Capture the OLD stored value first so the audit record carries old -> new.
    old_value = current_stored_profile()

    case SystemConfig.put(SignedProfilePolicy.profile_key(), value) do
      {:ok, setting} ->
        # Record the flip in the immutable, append-only audit log BEFORE reporting
        # success. Flipping this switch is a deployment-wide security control —
        # `:disable` in particular is a §9.3 downgrade (it drops the
        # cryptographic-attribution requirement on report/review-complete/verify)
        # — so its own change must leave a durable, tamper-evident record, not
        # just ephemeral stdout on the eval node.
        audit_custody_profile_flip(setting, old_value, value)

        # Reflect the just-written value in THIS node's cache so the status
        # printout below reads back the new value (running server nodes refresh
        # via the cron).
        SystemConfig.refresh()

        IO.puts("Set custody_signed_profile_enforcement = #{value} (#{profile_label(value)}).")
        print_custody_profile_status()
        :ok

      {:error, reason} ->
        IO.puts("Failed to set custody_signed_profile_enforcement = #{value}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp current_stored_profile do
    SystemConfig.refresh()
    SystemConfig.get_int(SignedProfilePolicy.profile_key(), 0)
  end

  # The deployment-wide custody profile has NO tenant, so the per-tenant
  # hash-chained `AuditChain` (which requires a tenant_id) is not the right sink.
  # The system-scoped `Audit` log explicitly accepts a nil tenant for
  # superadmin/system actions and is immutable + append-only (DB triggers), so it
  # gives the flip a durable, auditable residue. The entity is the SystemConfig
  # row that was flipped (a real, addressable UUID).
  defp audit_custody_profile_flip(setting, old_value, new_value) do
    action =
      if new_value == 1,
        do: "custody_signed_profile.enabled",
        else: "custody_signed_profile.disabled"

    attrs = %{
      entity_type: "system_config",
      entity_id: setting.id,
      action: action,
      actor_type: "system",
      actor_label: "release:custody_signed_profile",
      old_state: %{"value" => old_value, "profile" => profile_label(old_value)},
      new_state: %{"value" => new_value, "profile" => profile_label(new_value)},
      metadata: %{"key" => SignedProfilePolicy.profile_key(), "source" => "release_eval"}
    }

    case Audit.create_log_entry(nil, attrs) do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        # The config write already landed; surface the audit miss loudly rather
        # than let the flip look fully clean when its record did not persist.
        IO.puts(
          "WARNING: custody_signed_profile flip was NOT recorded in the audit log: " <>
            inspect(reason)
        )

        :ok
    end
  end

  @doc false
  def print_custody_profile_status do
    # The eval node does not run the app supervision tree, so its SystemConfig
    # persistent_term cache is unprimed — refresh from the DB before reading. Read
    # the STORED SystemConfig value (the deployment source of truth) rather than
    # SignedProfilePolicy.profile/0, which a test env can redirect through a stub.
    SystemConfig.refresh()
    code = SystemConfig.get_int(SignedProfilePolicy.profile_key(), 0)
    profile = profile_label(code)
    enrolled = count_enrolled_agent_keys()
    owner_tenants = count_owner_key_tenants()

    IO.puts("""
    LCP-1 §9 signed custody profile
      profile (stored DB row) : #{profile}  (SystemConfig custody_signed_profile_enforcement=#{code})
      enrolled dispatches     : #{enrolled}  (active agent signing keys, all tenants)
      tenants with owner key  : #{owner_tenants}
      enforcement scope       : report / review-complete / verify, for ENROLLED agents only
      bulk custody paths      : verify_all + bulk verify/mark_complete REFUSE enrolled agents under signed (bulk_signature_unsupported) — verify per-story instead
      NOT gated by this switch: Knowledge Wiki, memory, context retriever, auth, reads
      value shown             : the STORED DB row, NOT per-node live enforcement — confirm a node adopted it via its GET /.well-known/loopctl custody_profile
    #{status_hint(code, enrolled)}\
    """)

    :ok
  end

  @doc false
  def count_enrolled_agent_keys do
    now = DateTime.utc_now()

    AdminRepo.aggregate(
      from(d in Dispatch,
        where: not is_nil(d.agent_pubkey) and is_nil(d.revoked_at) and d.expires_at > ^now
      ),
      :count
    )
  end

  @doc false
  def count_owner_key_tenants do
    AdminRepo.aggregate(from(t in Tenant, where: not is_nil(t.custody_owner_pubkey)), :count)
  end

  defp status_hint(1, 0),
    do:
      "  hint                    : signed is ON but INERT — 0 enrolled dispatches, so every claim is waived."

  defp status_hint(1, _n),
    do: "  hint                    : signed is ON and ENFORCED for the enrolled dispatches above."

  defp status_hint(_code, _n),
    do:
      "  hint                    : bearer (default) — signatures are accepted but never required."

  defp profile_label(1), do: "signed"
  defp profile_label(0), do: "bearer"

  # Fail-safe for an out-of-band stored value (direct SQL, a raw SystemConfig.put/2,
  # a future admin API): the :status diagnostic — the tool an operator reaches for
  # to inspect a SUSPECTED bad value — must report it, not crash on it. This mirrors
  # SignedProfilePolicy.profile/0, which fail-safes an unrecognized code to :bearer.
  defp profile_label(other), do: "unknown(#{inspect(other)}) — treated as bearer"

  # Ensure AdminRepo is running for the duration of `fun`. `Ecto.Migrator.with_repo/2`
  # starts the repo if it is not already up (the eval-node case) and leaves an
  # already-started repo untouched (the test-sandbox case), so this is safe in both.
  defp with_admin_repo(fun) do
    load_app()

    # `with_repo/2` returns `{:error, reason}` when the repo cannot start (DB
    # unreachable / missing runtime config on the ephemeral eval node). Match it
    # and return a clean `{:error, reason}` — the declared @spec of
    # `custody_signed_profile/1` promises `:ok | {:error, term()}`, so a strict
    # `{:ok, _, _} = ...` here would raise a cryptic MatchError on DB-down instead.
    case Ecto.Migrator.with_repo(Loopctl.AdminRepo, fn _repo -> fun.() end) do
      {:ok, result, _apps} ->
        result

      {:error, reason} ->
        IO.puts("Could not start Loopctl.AdminRepo: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp load_app do
    # In a release this loads the app so config/deps resolve; in test the app is
    # already loaded (`{:error, {:already_loaded, _}}`), which is fine to ignore.
    _ = Application.load(@app)
    :ok
  end
end
