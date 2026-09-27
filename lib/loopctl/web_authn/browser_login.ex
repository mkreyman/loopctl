defmodule Loopctl.WebAuthn.BrowserLogin do
  @moduledoc """
  Browser login for the thread page (US-45.7, AC-45.7.1, PRD §6.1): the tenant's human signs
  in with the WebAuthn credential enrolled at signup, the L0 human anchor.

  ## One ceremony, not two

  Login IS `Loopctl.WebAuthn.Reauth`'s assertion ceremony under its own purpose,
  `"browser_login"`: a server-stored, single-use, TTL-bounded challenge whose
  `allow_credentials` are the tenant's enrolled `RootAuthenticator`s, consumed atomically
  before the assertion is verified against the stored COSE key, with the sign counter checked
  and persisted in one conditional update. Every failure is closed. A second ceremony would be
  a second place to get any of that wrong.

  ## One answer for every slug

  `begin/1` answers a slug that names no tenant, an inactive one or one with no authenticator
  with a DECOY challenge of the same shape as a real one: an unstored challenge id, fresh
  challenge bytes, and a credential id derived from the slug under an application secret, so
  a repeated try sees the same one. The login form carries only the challenge id; `complete/1`
  resolves the tenant from the STORED challenge, and a decoy id resolves to nothing and fails
  exactly as a replayed one does. Nothing a stranger sees tells a real slug from an invented
  one, and no tenant id reaches the page. What remains is timing: a real challenge costs a
  lookup and an insert that a decoy does not.

  There is deliberately no per-TENANT budget. A budget keyed on something a stranger can name
  is a lock a stranger can close on the tenant's own human. The budgets are per CLIENT, in the
  web layer (`LoopctlWeb.LoginLive`, `LoopctlWeb.BrowserSessionController`), and a challenge is
  short-lived and single-use.

  ## What a session is

  A `browser_sessions` row bound to the tenant and the authenticator that asserted; the cookie
  carries only its id and tenant. The principal it writes as is
  `Loopctl.Threads.human_principal/0` with an empty lineage — the human-operator shape PRD §6.1
  names. It carries no key and no role.

  ## When a session ends

  `validate/2` is asked on EVERY request and every LiveView mount, and again before every write
  and on a timer while a page is open. It reads the row under the tenant's RLS, so each of these
  ends a session on the next ask:

  - the absolute lifetime (`lifetime_seconds/0`) has passed since the assertion;
  - logout revoked the row (`revoke/1`) — a copied cookie dies with it;
  - the authenticator was revoked (`Loopctl.Tenants.Enrollment.revoke/2` deletes it, and the
    row goes with it by `ON DELETE CASCADE`);
  - the tenant is no longer `:active`, or no longer exists.

  A custody HALT does not end a session: reads stay open during a halt, as they do on the API
  (`LoopctlWeb.CustodySurface`), and the writes a halt suspends are refused by
  `Loopctl.Threads` itself.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Repo
  alias Loopctl.Tenants
  alias Loopctl.Tenants.Tenant
  alias Loopctl.WebAuthn.BrowserSession
  alias Loopctl.WebAuthn.Reauth
  alias Loopctl.WebAuthn.ReauthChallenge
  alias Plug.Crypto.KeyGenerator

  @purpose "browser_login"

  # Short and absolute: a working day. The page is where a human reads and writes a thread,
  # not a console left open for a week, and a session that outlived its authenticator's owner
  # would be the one standing credential in a system built to have none.
  @lifetime_seconds 8 * 60 * 60

  # The length of a decoy credential id and challenge. A platform or roaming authenticator's
  # credential id is commonly this long; a challenge is what the adapter issues.
  @decoy_credential_bytes 32
  @decoy_challenge_bytes 32

  @typedoc "An authenticated browser session, as `validate/2` returns it."
  @type principal :: %{
          tenant_id: Ecto.UUID.t(),
          session_id: Ecto.UUID.t(),
          authenticator_id: Ecto.UUID.t(),
          authenticated_at: DateTime.t()
        }

  @doc "The Reauth purpose a login challenge is issued and consumed under."
  @spec purpose() :: String.t()
  def purpose, do: @purpose

  @doc "The absolute lifetime of a browser session, in seconds."
  @spec lifetime_seconds() :: pos_integer()
  def lifetime_seconds, do: @lifetime_seconds

  @doc """
  A login challenge for the tenant named by `slug`: `challenge_id`, `challenge`,
  `allowed_credentials`, `rp_id` and `expires_at`, the same keys and shapes whether `slug` names
  a tenant that can sign in or not (see the moduledoc). `{:error, :unavailable}` only when a
  real challenge could not be stored.
  """
  @spec begin(term()) :: {:ok, map()} | {:error, :unavailable}
  def begin(slug) do
    with slug when is_binary(slug) <- slug,
         {:ok, %Tenant{status: :active} = tenant} <- Tenants.get_tenant_by_slug(String.trim(slug)),
         {:ok, issued} <- Reauth.issue_challenge(tenant.id, @purpose) do
      {:ok,
       Map.take(issued, [:challenge_id, :challenge, :allowed_credentials, :rp_id, :expires_at])}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :unavailable}
      _no_login_here -> {:ok, decoy(slug)}
    end
  end

  defp decoy(slug) do
    credential =
      :hmac
      |> :crypto.mac(:sha256, decoy_key(), "browser_login decoy:" <> to_string_slug(slug))
      |> binary_part(0, @decoy_credential_bytes)

    %{
      challenge_id: Ecto.UUID.generate(),
      challenge:
        @decoy_challenge_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false),
      allowed_credentials: [Base.url_encode64(credential, padding: false)],
      rp_id: Keyword.get(Loopctl.WebAuthn.rp_opts(), :rp_id),
      expires_at: DateTime.add(DateTime.utc_now(), Reauth.challenge_ttl_seconds(), :second)
    }
  end

  defp to_string_slug(slug) when is_binary(slug), do: String.trim(slug)
  defp to_string_slug(_slug), do: ""

  # Derived from the endpoint's secret, so a decoy id is stable per slug for this deployment
  # and unpredictable without the secret.
  defp decoy_key do
    :loopctl
    |> Application.fetch_env!(LoopctlWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
    |> KeyGenerator.generate("browser_login decoy", length: 32)
  end

  @doc """
  Verifies a login assertion — the `Reauth.verify_and_consume/3` params, `challenge_id`
  included — and opens a session. The tenant is the one the STORED challenge was issued for,
  never one the client names; an id no challenge carries (a decoy, a replay, an expired one)
  is `{:error, :challenge_not_found}`. Fails closed on every error.
  """
  @spec complete(map()) :: {:ok, principal()} | {:error, term()}
  def complete(%{"challenge_id" => challenge_id} = params) when is_binary(challenge_id) do
    with {:ok, tenant_id} <- challenge_tenant(challenge_id),
         {:ok, %Tenant{status: :active}} <- Tenants.get_tenant(tenant_id),
         {:ok, %{authenticator: authenticator}} <-
           Reauth.verify_and_consume(tenant_id, @purpose, params) do
      open_session(tenant_id, authenticator.id)
    else
      {:ok, %Tenant{}} -> {:error, :tenant_inactive}
      {:error, _reason} = error -> error
    end
  end

  def complete(_params), do: {:error, :challenge_not_found}

  # Only WHICH tenant: whether the challenge may be consumed — its purpose, expiry and single use
  # — is `Reauth.verify_and_consume/3`'s to decide, and it decides it atomically.
  defp challenge_tenant(challenge_id) do
    with {:ok, id} <- Ecto.UUID.cast(challenge_id),
         tenant_id when is_binary(tenant_id) <-
           AdminRepo.one(from c in ReauthChallenge, where: c.id == ^id, select: c.tenant_id) do
      {:ok, tenant_id}
    else
      _none -> {:error, :challenge_not_found}
    end
  end

  # Also clears the tenant's expired sessions, so the table holds at most what is live plus
  # what expired since this tenant's last login.
  defp open_session(tenant_id, authenticator_id) do
    now = DateTime.utc_now()

    AdminRepo.delete_all(
      from s in BrowserSession, where: s.tenant_id == ^tenant_id and s.expires_at <= ^now
    )

    session =
      AdminRepo.insert!(%BrowserSession{
        tenant_id: tenant_id,
        authenticator_id: authenticator_id,
        expires_at: DateTime.add(now, @lifetime_seconds, :second)
      })

    {:ok,
     %{
       tenant_id: tenant_id,
       session_id: session.id,
       authenticator_id: authenticator_id,
       authenticated_at: session.inserted_at
     }}
  end

  @doc "Ends a session now, on the server: every copy of its cookie stops validating."
  @spec revoke(term()) :: :ok
  def revoke(%{"tenant_id" => tenant_id, "session_id" => session_id} = session) do
    if well_formed?(session) do
      AdminRepo.update_all(
        from(s in BrowserSession,
          where: s.id == ^session_id and s.tenant_id == ^tenant_id and is_nil(s.revoked_at)
        ),
        set: [revoked_at: DateTime.utc_now()]
      )
    end

    :ok
  end

  def revoke(_session), do: :ok

  @doc "The session (cookie) value for `principal`: its tenant and its row, nothing else."
  @spec to_session(principal()) :: map()
  def to_session(%{tenant_id: tenant_id, session_id: session_id}),
    do: %{"tenant_id" => tenant_id, "session_id" => session_id}

  @doc """
  Whether a stored session value still authenticates at `now`: its row exists under the
  tenant's RLS, is neither revoked nor expired, and its tenant is `:active`. Asked on every
  request; see the moduledoc for what ends a session.
  """
  @spec validate(term(), DateTime.t()) :: {:ok, principal()} | {:error, :no_session}
  def validate(session, now \\ DateTime.utc_now())

  def validate(%{"tenant_id" => tenant_id, "session_id" => session_id} = session, now) do
    if well_formed?(session) do
      {:ok, principal} =
        Repo.with_tenant(tenant_id, fn -> Repo.one(live_session(tenant_id, session_id, now)) end)

      if principal, do: {:ok, principal}, else: {:error, :no_session}
    else
      {:error, :no_session}
    end
  end

  def validate(_session, _now), do: {:error, :no_session}

  defp live_session(tenant_id, session_id, now) do
    from s in BrowserSession,
      join: t in Tenant,
      on: t.id == s.tenant_id,
      where: s.id == ^session_id and s.tenant_id == ^tenant_id,
      where: is_nil(s.revoked_at) and s.expires_at > ^now and t.status == :active,
      select: %{
        tenant_id: s.tenant_id,
        session_id: s.id,
        authenticator_id: s.authenticator_id,
        authenticated_at: s.inserted_at
      }
  end

  defp well_formed?(%{"tenant_id" => tenant_id, "session_id" => session_id}) do
    match?({:ok, _}, cast(tenant_id)) and match?({:ok, _}, cast(session_id))
  end

  defp cast(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast(_value), do: :error
end
