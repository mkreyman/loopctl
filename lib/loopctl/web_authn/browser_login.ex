defmodule Loopctl.WebAuthn.BrowserLogin do
  @moduledoc """
  Browser login for the thread page (US-45.7, AC-45.7.1, PRD §6.1): the tenant's human signs
  in with the WebAuthn credential enrolled at signup, the L0 human anchor.

  ## Usernameless, on Reauth's ceremony

  There is no slug, no tenant and no credential list on the way in. `begin/0` issues a challenge
  with EMPTY `allow_credentials` (`Loopctl.WebAuthn.Reauth.issue_discoverable_challenge/1`), the
  browser offers whichever discoverable credential (a passkey, or a security key holding a
  resident credential) it has for loopctl, and `complete/1` identifies the authenticator by the
  assertion's credential id — globally unique — and the tenant by the authenticator. So nothing
  the login page sends or answers depends on any tenant: every visitor gets the same shape, and
  an unknown credential fails exactly as a bad signature does. User verification is required.

  The rest is `Reauth`'s ceremony: a stored, single-use, TTL-bounded challenge consumed before
  anything is looked up, the assertion verified against the enrolled authenticator's stored COSE
  key, and the sign counter checked and persisted in one conditional update. Every failure is
  closed.

  A credential enrolled without a resident key (enrollment asks for one as `"preferred"`, not
  `"required"`) cannot sign in here; its holder enrolls a passkey.

  There is no per-TENANT budget: a budget keyed on something a stranger can name is a lock a
  stranger can close on the tenant's own human. The budgets are per CLIENT, in the web layer
  (`LoopctlWeb.LoginLive`, `LoopctlWeb.BrowserSessionController`).

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

  @purpose "browser_login"

  # Short and absolute: a working day. The page is where a human reads and writes a thread,
  # not a console left open for a week, and a session that outlived its authenticator's owner
  # would be the one standing credential in a system built to have none.
  @lifetime_seconds 8 * 60 * 60

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
  A usernameless login challenge: `challenge_id`, `challenge`, `allowed_credentials` (always
  empty), `rp_id` and `expires_at`. It takes no input, so it is the same for everyone.
  `{:error, :unavailable}` only when the challenge could not be stored.
  """
  @spec begin() :: {:ok, map()} | {:error, :unavailable}
  def begin do
    case Reauth.issue_discoverable_challenge(@purpose) do
      {:ok, issued} -> {:ok, issued}
      {:error, _changeset} -> {:error, :unavailable}
    end
  end

  @doc """
  Verifies a usernameless login assertion — `challenge_id`, `credential_id`,
  `authenticator_data`, `signature`, `client_data_json` — and opens a session for the tenant the
  asserting authenticator is enrolled in. Fails closed on every error; an unknown credential is
  `{:error, :invalid_assertion}`, as a bad signature is.
  """
  @spec complete(map()) :: {:ok, principal()} | {:error, term()}
  def complete(params) when is_map(params) do
    with {:ok, %{authenticator: authenticator}} <-
           Reauth.verify_discoverable_and_consume(@purpose, params),
         {:ok, %Tenant{status: :active}} <- Tenants.get_tenant(authenticator.tenant_id) do
      open_session(authenticator.tenant_id, authenticator.id)
    else
      {:ok, %Tenant{}} -> {:error, :tenant_inactive}
      {:error, _reason} = error -> error
    end
  end

  def complete(_params), do: {:error, :invalid_assertion}

  # Also clears the tenant's expired sessions, so the table holds at most what is live plus
  # what expired since this tenant's last login.
  @doc false
  @spec open_session(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, principal()} | {:error, term()}
  def open_session(tenant_id, authenticator_id) do
    now = DateTime.utc_now()

    AdminRepo.delete_all(
      from s in BrowserSession, where: s.tenant_id == ^tenant_id and s.expires_at <= ^now
    )

    # The authenticator can be revoked between its assertion and this insert: the foreign key
    # then refuses the row, and that is a refused login, not a crash.
    %BrowserSession{
      tenant_id: tenant_id,
      authenticator_id: authenticator_id,
      expires_at: DateTime.add(now, @lifetime_seconds, :second)
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:authenticator_id,
      name: :browser_sessions_authenticator_id_fkey
    )
    |> Ecto.Changeset.foreign_key_constraint(:tenant_id, name: :browser_sessions_tenant_id_fkey)
    |> AdminRepo.insert()
    |> case do
      {:ok, session} ->
        {:ok,
         %{
           tenant_id: tenant_id,
           session_id: session.id,
           authenticator_id: authenticator_id,
           authenticated_at: session.inserted_at
         }}

      {:error, _changeset} ->
        {:error, :authenticator_revoked}
    end
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
