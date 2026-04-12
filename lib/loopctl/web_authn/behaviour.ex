defmodule Loopctl.WebAuthn.Behaviour do
  @moduledoc """
  Behaviour for WebAuthn (FIDO2) registration and authentication ceremonies.

  Wraps a FIDO2-verified Elixir library (by default `Wax`) so the application
  can swap the implementation for tests. Follows loopctl's config-based DI
  convention — see `config/config.exs` and `config/test.exs`.

  The implementation verifies the attestation statement, extracts the
  credential ID, COSE public key, attestation format, and sign counter, and
  returns them in a normalized map.
  """

  @typedoc """
  Options passed when generating a new challenge. The default
  implementation expects `:rp_id`, `:origin`, and optionally
  `:user_verification`.
  """
  @type challenge_opts :: keyword()

  @typedoc """
  Normalized attestation result returned by `verify_registration/3`.

  - `:credential_id` — raw FIDO2 credential id (bytes)
  - `:public_key` — COSE-encoded public key (bytes)
  - `:attestation_format` — attestation format string ("packed", "fido-u2f", "none", ...)
  - `:sign_count` — authenticator signature counter
  """
  @type registration_result :: %{
          credential_id: binary(),
          public_key: binary(),
          attestation_format: String.t(),
          sign_count: non_neg_integer()
        }

  @typedoc """
  Raw attestation payload posted back from the browser.

  Matches the shape of `PublicKeyCredential.response` for a `create()` call,
  with base64url-decoded binaries.
  """
  @type attestation_payload :: %{
          required(:attestation_object) => binary(),
          required(:client_data_json) => binary(),
          optional(:credential_id) => binary()
        }

  @type auth_payload :: %{
          required(:credential_id) => binary(),
          required(:authenticator_data) => binary(),
          required(:signature) => binary(),
          required(:client_data_json) => binary()
        }

  @type challenge :: term()

  @doc "Generates a new registration challenge."
  @callback new_registration_challenge(challenge_opts()) :: challenge()

  @doc """
  Verifies a registration response from the browser and returns the
  normalized attestation result.
  """
  @callback verify_registration(attestation_payload(), challenge(), challenge_opts()) ::
              {:ok, registration_result()} | {:error, term()}

  @doc "Generates a new authentication challenge."
  @callback new_authentication_challenge(challenge_opts()) :: challenge()

  @doc """
  Verifies an authentication assertion from the browser and returns the
  updated sign counter on success.
  """
  @callback verify_authentication(auth_payload(), challenge(), challenge_opts()) ::
              {:ok, %{sign_count: non_neg_integer()}} | {:error, term()}
end
