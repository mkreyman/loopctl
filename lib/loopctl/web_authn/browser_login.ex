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

  ## What a session is bound to

  The tenant, and the authenticator that asserted, stamped with the time it did. The principal
  it writes as is `Loopctl.Threads.human_principal/0` with an empty lineage — the
  human-operator shape PRD §6.1 names. The session carries no key and no role; it grants
  exactly what the thread page does with it.

  ## When a session ends

  `validate/2` is asked on EVERY request and every LiveView mount, and again before every
  write and on a timer while a page is open, so each of these ends it on the next ask:

  - the absolute lifetime (`lifetime_seconds/0`) has passed since the assertion. It is
    absolute, not idle: a stolen cookie is good for at most this long however it is used;
  - the authenticator was revoked (`Loopctl.Tenants.Enrollment.revoke/2` deletes the row);
  - the tenant is no longer `:active`, or no longer exists.

  A custody HALT does not end a session: reads stay open during a halt, as they do on the API
  (`LoopctlWeb.CustodySurface`), and the writes a halt suspends are refused by
  `Loopctl.Threads` itself.
  """

  alias Loopctl.Tenants
  alias Loopctl.Tenants.RootAuthenticators
  alias Loopctl.WebAuthn.Reauth

  @purpose "browser_login"

  # Short and absolute: a working day. The page is where a human reads and writes a thread,
  # not a console left open for a week, and a session that outlived its authenticator's owner
  # would be the one standing credential in a system built to have none.
  @lifetime_seconds 8 * 60 * 60

  # Per TENANT, fail-closed, on top of the web layer's per-IP budget: issuing a challenge writes
  # a row and verifying one is CPU-bound, and a tenant's human signs in a handful of times a day.
  # The same shape as `LoopctlWeb.TenantAuthenticatorController`'s ceremony budget.
  @rate_window_ms 60 * 60_000
  @max_per_window 60

  @typedoc "What a session holds, and what `validate/2` returns when it still holds."
  @type principal :: %{
          tenant_id: Ecto.UUID.t(),
          authenticator_id: Ecto.UUID.t(),
          authenticated_at: integer()
        }

  @doc "The Reauth purpose a login challenge is issued and consumed under."
  @spec purpose() :: String.t()
  def purpose, do: @purpose

  @doc "The absolute lifetime of a browser session, in seconds."
  @spec lifetime_seconds() :: pos_integer()
  def lifetime_seconds, do: @lifetime_seconds

  @doc """
  Issues a login challenge for the tenant named by `slug`.

  `{:error, :unavailable}` for every reason one cannot be issued — no such tenant, a tenant not
  `:active`, no enrolled authenticator — deliberately one answer, so the login form does not
  tell a stranger which slugs exist. `{:error, :rate_limited}` past the tenant's budget, which
  does say the slug exists, to someone who has already spent that budget on it.
  """
  @spec begin(String.t()) :: {:ok, map()} | {:error, :unavailable}
  def begin(slug) when is_binary(slug) do
    with {:ok, tenant} <- Tenants.get_tenant_by_slug(String.trim(slug)),
         :active <- tenant.status,
         :ok <- budget("challenge", tenant.id),
         {:ok, issued} <- Reauth.issue_challenge(tenant.id, @purpose) do
      {:ok, Map.put(issued, :tenant_id, tenant.id)}
    else
      {:error, :rate_limited} = limited -> limited
      _unavailable -> {:error, :unavailable}
    end
  end

  def begin(_slug), do: {:error, :unavailable}

  @doc """
  Verifies a login assertion (the `Reauth.verify_and_consume/3` params) for `tenant_id` and
  returns the principal to bind the session to. Fails closed on every error.
  """
  @spec complete(Ecto.UUID.t(), map()) :: {:ok, principal()} | {:error, term()}
  def complete(tenant_id, params) when is_binary(tenant_id) and is_map(params) do
    with {:ok, tenant_id} <- cast_id(tenant_id),
         {:ok, tenant} <- Tenants.get_tenant(tenant_id),
         :active <- tenant.status,
         :ok <- budget("verify", tenant.id),
         {:ok, %{authenticator: authenticator}} <-
           Reauth.verify_and_consume(tenant.id, @purpose, params) do
      {:ok,
       %{
         tenant_id: tenant.id,
         authenticator_id: authenticator.id,
         authenticated_at: System.system_time(:second)
       }}
    else
      {:error, _reason} = error -> error
      _inactive -> {:error, :tenant_inactive}
    end
  end

  def complete(_tenant_id, _params), do: {:error, :invalid_login}

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_login}
    end
  end

  @doc "The session value for `principal`: string keys, as a cookie session stores them."
  @spec to_session(principal()) :: map()
  def to_session(%{tenant_id: tenant_id, authenticator_id: id, authenticated_at: at}),
    do: %{"tenant_id" => tenant_id, "authenticator_id" => id, "authenticated_at" => at}

  @doc """
  Whether a stored session value still authenticates, at `now` (unix seconds). Asked on every
  request; see the moduledoc for what ends a session.
  """
  @spec validate(term(), integer()) :: {:ok, principal()} | {:error, atom()}
  def validate(session, now \\ System.system_time(:second))

  def validate(
        %{"tenant_id" => tenant_id, "authenticator_id" => id, "authenticated_at" => at},
        now
      )
      when is_binary(tenant_id) and is_binary(id) and is_integer(at) do
    principal = %{tenant_id: tenant_id, authenticator_id: id, authenticated_at: at}

    with :ok <- well_formed(tenant_id, id),
         :ok <- within_lifetime(at, now),
         :ok <- still_holds(tenant_id, id) do
      {:ok, principal}
    end
  end

  def validate(_session, _now), do: {:error, :no_session}

  defp budget(action, tenant_id) do
    if Loopctl.RateLimiter.gate_ok?(
         "browser_login:#{action}:tenant:#{tenant_id}",
         @rate_window_ms,
         @max_per_window
       ),
       do: :ok,
       else: {:error, :rate_limited}
  end

  defp well_formed(tenant_id, id) do
    if match?({:ok, _}, Ecto.UUID.cast(tenant_id)) and match?({:ok, _}, Ecto.UUID.cast(id)),
      do: :ok,
      else: {:error, :no_session}
  end

  # Absolute from the assertion; a stamp from the future (beyond a minute of clock skew) is not
  # one this server wrote, and does not extend the lifetime.
  defp within_lifetime(at, now) do
    if now - at <= @lifetime_seconds and at <= now + 60, do: :ok, else: {:error, :expired}
  end

  defp still_holds(tenant_id, id) do
    cond do
      not active?(tenant_id) -> {:error, :tenant_inactive}
      not RootAuthenticators.enrolled?(tenant_id, id) -> {:error, :authenticator_revoked}
      true -> :ok
    end
  end

  defp active?(tenant_id) do
    match?({:ok, %{status: :active}}, Tenants.get_tenant(tenant_id))
  end
end
