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

  alias Loopctl.WebAuthn.RpConfig

  @hooks ["assets/js/hooks/webauthn.js", "assets/js/hooks/authenticator_enroll.js"]

  describe "client/server attestation conveyance agreement" do
    test "no :attestation override reaches the config, compiled OR resolved at boot" do
      configured = :loopctl |> Application.get_env(:webauthn, []) |> Keyword.get(:attestation)

      assert is_nil(configured),
             "config :loopctl, :webauthn now sets attestation: #{inspect(configured)}. " <>
               "The browser hooks (#{Enum.join(@hooks, ", ")}) hard-code the conveyance " <>
               "they request and must be updated to match, or every registration will " <>
               "fail with :invalid_attestation_conveyance_preference."

      # config/test.exs is only half the surface. Production ASSEMBLES `:webauthn`
      # at boot from `RpConfig.resolve/1` (config/runtime.exs), which no test env
      # can observe — so an override added there would leave this file green while
      # every real registration failed. Drive the resolver directly, both with a
      # fully-populated operator env and with none, so the prod path is covered too.
      for env <- [
            [rp_id: "loopctl.com", rp_name: "loopctl", origin: "https://loopctl.com"],
            [rp_id: nil, rp_name: nil, origin: nil, phx_host: "loopctl.com"]
          ] do
        {opts, _warnings} = RpConfig.resolve(env)

        refute Keyword.has_key?(opts, :attestation),
               "RpConfig.resolve/1 now emits attestation: " <>
                 "#{inspect(Keyword.get(opts, :attestation))} for #{inspect(env)}. " <>
                 "That reaches `config :loopctl, :webauthn` in production only, where " <>
                 "the hooks' hard-coded \"none\" no longer matches and Wax.register/3 " <>
                 "rejects every attestation with " <>
                 ":invalid_attestation_conveyance_preference."
      end

      # The resolver is not the only writer: runtime.exs MERGES its output into
      # `config :loopctl, :webauthn` (config/runtime.exs:568), so an
      # `attestation:` key appended at THAT call site — or in prod.exs — is
      # outside both surfaces above and would leave this file green. Scan the
      # config sources the way the test below scans the hooks.
      for path <- ["config/runtime.exs", "config/prod.exs"] do
        refute File.read!(path) =~ ~r/attestation:/,
               "#{path} now sets an attestation conveyance preference. The browser " <>
                 "hooks hard-code \"none\" and must be updated to match, or every " <>
                 "production registration fails with " <>
                 ":invalid_attestation_conveyance_preference."
      end
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
