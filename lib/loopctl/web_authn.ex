defmodule Loopctl.WebAuthn do
  @moduledoc """
  Thin facade over the configured `Loopctl.WebAuthn.Behaviour` adapter.

  Resolves the adapter via `Application.get_env/3` so tests can swap it
  for `Loopctl.MockWebAuthn` through `config/test.exs`.
  """

  @behaviour Loopctl.WebAuthn.Behaviour

  @impl true
  def new_registration_challenge(opts \\ []) do
    adapter().new_registration_challenge(opts)
  end

  @impl true
  def verify_registration(payload, challenge, opts \\ []) do
    adapter().verify_registration(payload, challenge, opts)
  end

  @impl true
  def new_authentication_challenge(opts \\ []) do
    adapter().new_authentication_challenge(opts)
  end

  @impl true
  def verify_authentication(payload, challenge, opts \\ []) do
    adapter().verify_authentication(payload, challenge, opts)
  end

  @doc """
  Returns the configured relying party options used by the signup LiveView
  and future reauth flows. Configured in `config/<env>.exs` under
  `:loopctl, :webauthn`.
  """
  @spec rp_opts() :: keyword()
  def rp_opts do
    Application.get_env(:loopctl, :webauthn, [])
  end

  defp adapter do
    Application.get_env(:loopctl, :webauthn_adapter, Loopctl.WebAuthn.Wax)
  end
end
