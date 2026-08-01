defmodule Loopctl.WebAuthn.AttestationConveyanceTest do
  @moduledoc """
  Binds the browser's requested attestation conveyance preference to the one
  the server actually accepts.

  `Wax.new_registration_challenge/1` stores an `attestation` preference on the
  challenge and `Wax.register/3` REJECTS any attestation statement that does not
  match it (`:invalid_attestation_conveyance_preference`). Wax defaults that to
  `"none"`, and this app passes no override — `config :loopctl, :webauthn`
  carries only `rp_id` / `rp_name` / `origin` / `user_verification`.

  Both hooks nonetheless requested `attestation: "direct"`. That failure is
  invisible on the common path, which is what let it survive: platform
  authenticators (Touch ID, Windows Hello) generally return `fmt: "none"`
  whatever the page asks for, so verification passed. A roaming key returns a
  `packed` statement, and Wax then rejects a perfectly valid credential. It was
  found by driving /enroll with a CTAP2 virtual authenticator, which behaves
  like the YubiKey rather than like the laptop.

  These assertions fail in BOTH directions, so the pair cannot drift apart:
  configure `:attestation` server-side without updating the hooks, or change a
  hook without configuring the server, and this test says so.
  """

  use ExUnit.Case, async: true

  @hooks ["assets/js/hooks/webauthn.js", "assets/js/hooks/authenticator_enroll.js"]

  describe "client/server attestation conveyance agreement" do
    test "the app configures no :attestation override, so the effective policy is Wax's \"none\"" do
      configured = :loopctl |> Application.get_env(:webauthn, []) |> Keyword.get(:attestation)

      assert is_nil(configured),
             "config :loopctl, :webauthn now sets attestation: #{inspect(configured)}. " <>
               "The browser hooks (#{Enum.join(@hooks, ", ")}) hard-code the conveyance " <>
               "they request and must be updated to match, or every registration will " <>
               "fail with :invalid_attestation_conveyance_preference."
    end

    test "every hook requests attestation: \"none\"" do
      for hook <- @hooks do
        source = File.read!(hook)

        assert source =~ ~s(attestation: "none"),
               "#{hook} must request attestation: \"none\" to match the server."

        refute source =~ ~s(attestation: "direct"),
               "#{hook} requests attestation: \"direct\", which Wax rejects unless the " <>
                 "server challenge is built with the same preference."
      end
    end
  end
end
