defmodule Loopctl.WebAuthn.Wax do
  @moduledoc """
  Default `Loopctl.WebAuthn.Behaviour` implementation backed by the Wax
  library (https://github.com/tanguilp/wax).

  Verifies FIDO2/WebAuthn attestation statements against the configured
  relying party ID and origin. Returns the credential id, COSE-encoded
  public key, attestation format and sign counter for persistence in
  `tenant_root_authenticators`.
  """

  @behaviour Loopctl.WebAuthn.Behaviour

  require Logger

  @impl true
  def new_registration_challenge(opts) do
    opts
    |> normalize_opts()
    |> Wax.new_registration_challenge()
  end

  @impl true
  def verify_registration(payload, challenge, _opts) do
    attestation_object = Map.fetch!(payload, :attestation_object)
    client_data_json = Map.fetch!(payload, :client_data_json)

    case Wax.register(attestation_object, client_data_json, challenge) do
      {:ok, {auth_data, {_att_type, _trust_path, _metadata}}} ->
        att_cred = auth_data.attested_credential_data

        fmt = extract_fmt(attestation_object)

        {:ok,
         %{
           credential_id: att_cred.credential_id,
           public_key: encode_cose_key(att_cred.credential_public_key),
           attestation_format: fmt,
           sign_count: auth_data.sign_count
         }}

      {:error, reason} ->
        Logger.warning("WebAuthn registration failed: #{inspect(reason)}")
        {:error, :invalid_attestation}
    end
  end

  @impl true
  def new_authentication_challenge(opts) do
    opts
    |> normalize_opts()
    |> Wax.new_authentication_challenge()
  end

  @impl true
  def verify_authentication(payload, challenge, _opts) do
    credential_id = Map.fetch!(payload, :credential_id)
    auth_data = Map.fetch!(payload, :authenticator_data)
    signature = Map.fetch!(payload, :signature)
    client_data_json = Map.fetch!(payload, :client_data_json)

    case Wax.authenticate(credential_id, auth_data, signature, client_data_json, challenge, []) do
      {:ok, auth_data} -> {:ok, %{sign_count: auth_data.sign_count}}
      {:error, _reason} -> {:error, :invalid_assertion}
    end
  end

  defp normalize_opts(opts) do
    defaults = Application.get_env(:loopctl, :webauthn_defaults, [])
    Keyword.merge(defaults, opts)
  end

  # CBOR-decode the attestation object header so we can surface the
  # attestation format without re-parsing it from Wax's return value.
  defp extract_fmt(attestation_object) do
    case CBOR.decode(attestation_object) do
      {:ok, %{"fmt" => fmt}, _rest} when is_binary(fmt) -> fmt
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  # Wax returns COSE keys as Elixir maps with integer keys. We persist
  # them in the database as :erlang.term_to_binary so verification can
  # round-trip without a second parser implementation.
  defp encode_cose_key(cose_key) when is_map(cose_key) do
    :erlang.term_to_binary(cose_key)
  end
end
