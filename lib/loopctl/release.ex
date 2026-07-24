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
  to cryptographically sign its custody claims at the three custody gates —
  `report`, `review-complete`, `verify` — enforced by
  `LoopctlWeb.Plugs.RequireSignedClaim`, which is mounted ONLY on those three
  routes. It therefore:

    * does **NOT** gate the Knowledge Wiki, agent memory, the context retriever,
      or ANY read path — **KB access cannot be lost by enabling this**;
    * does **NOT** gate authentication, signup, or tenant access;
    * is **enrolled-only / gradual**: a caller WITHOUT an enrolled signing key is
      waived (proceeds), so with zero enrolled agents the switch is INERT — it
      changes nothing observable until you register a tenant owner key and enroll
      an agent. `:status` reports the enrolled count so you flip with eyes open.

  Fully reversible (`:disable`). `:enable`/`:disable` write the DB value; every
  running node adopts it within a minute via `SystemConfigRefreshWorker` (and on
  next boot) — no redeploy. The `eval` node's own in-memory cache is irrelevant
  (it exits immediately); the DB row is the source of truth.
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
    {:ok, _setting} = SystemConfig.put(SignedProfilePolicy.profile_key(), value)
    # Reflect the just-written value in THIS node's cache so the status printout
    # below reads back the new value (running server nodes refresh via the cron).
    SystemConfig.refresh()

    IO.puts("Set custody_signed_profile_enforcement = #{value} (#{profile_label(value)}).")
    print_custody_profile_status()
    :ok
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
      profile                : #{profile}  (SystemConfig custody_signed_profile_enforcement=#{code})
      enrolled agent keys    : #{enrolled}  (active signing keys, all tenants)
      tenants with owner key : #{owner_tenants}
      enforcement scope      : report / review-complete / verify, for ENROLLED agents only
      NOT gated by this switch: Knowledge Wiki, memory, context retriever, auth, reads
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
      "  hint                   : signed is ON but INERT — 0 enrolled agents, so every claim is waived."

  defp status_hint(1, _n),
    do: "  hint                   : signed is ON and ENFORCED for the enrolled agents above."

  defp status_hint(_code, _n),
    do:
      "  hint                   : bearer (default) — signatures are accepted but never required."

  defp profile_label(1), do: "signed"
  defp profile_label(0), do: "bearer"

  # Ensure AdminRepo is running for the duration of `fun`. `Ecto.Migrator.with_repo/2`
  # starts the repo if it is not already up (the eval-node case) and leaves an
  # already-started repo untouched (the test-sandbox case), so this is safe in both.
  defp with_admin_repo(fun) do
    load_app()
    {:ok, result, _} = Ecto.Migrator.with_repo(Loopctl.AdminRepo, fn _repo -> fun.() end)
    result
  end

  defp load_app do
    # In a release this loads the app so config/deps resolve; in test the app is
    # already loaded (`{:error, {:already_loaded, _}}`), which is fine to ignore.
    _ = Application.load(@app)
    :ok
  end
end
