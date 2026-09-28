defmodule Loopctl.Verification.CredentialTest do
  @moduledoc """
  US-26.4.6, AC-26.4.6.8: the operator's `GITHUB_TOKEN` is lent only to tenants the operator
  named. `config/test.exs` names two fixed ids (one padded and upper-cased) and one entry that
  is not a UUID; no fixture ever creates a tenant with either id.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Verification.Credential
  alias Loopctl.Verification.OperatorCredential

  @named "0000a110-0000-4000-8000-00000000a110"
  @named_padded "0000a110-0000-4000-8000-00000000b220"

  describe "OperatorCredential.for_tenant/1" do
    test "a named tenant gets the operator credential" do
      assert {:ok, %Credential{kind: :operator_token}} = OperatorCredential.for_tenant(@named)
    end

    test "an entry is matched trimmed and case-insensitively" do
      assert {:ok, %Credential{}} = OperatorCredential.for_tenant(@named_padded)
      assert {:ok, %Credential{}} = OperatorCredential.for_tenant(String.upcase(@named))
    end

    test "TC-26.4.6.6 any other tenant has no credential" do
      assert OperatorCredential.for_tenant(Ecto.UUID.generate()) ==
               {:error, :credential_unavailable}

      assert OperatorCredential.for_tenant("not-a-uuid") == {:error, :credential_unavailable}
      assert OperatorCredential.for_tenant(nil) == {:error, :credential_unavailable}
    end

    test "an entry that is not a UUID is dropped from the allowlist" do
      assert Enum.sort(OperatorCredential.allowlist()) == Enum.sort([@named, @named_padded])
    end
  end

  describe "the token never leaks" do
    test "inspecting a credential omits the token" do
      refute inspect(%Credential{kind: :operator_token, token: "ghp_secret"}) =~ "ghp_secret"
    end

    test "git_env scopes the header to github.com, refuses redirects and never prompts" do
      env = Map.new(Credential.git_env(%Credential{kind: :operator_token, token: " ghp_x \n"}))

      assert env["GIT_TERMINAL_PROMPT"] == "0"
      assert env["GIT_CONFIG_COUNT"] == "2"
      assert env["GIT_CONFIG_KEY_0"] == "http.followRedirects"
      assert env["GIT_CONFIG_VALUE_0"] == "false"
      assert env["GIT_CONFIG_KEY_1"] == "http.https://github.com/.extraheader"

      assert env["GIT_CONFIG_VALUE_1"] ==
               "AUTHORIZATION: basic " <> Base.encode64("x-access-token:ghp_x")
    end

    test "no token and a blank token send no header at all" do
      for token <- [nil, "", "  "] do
        env = Map.new(Credential.git_env(%Credential{kind: :operator_token, token: token}))
        assert env["GIT_CONFIG_COUNT"] == "1", inspect(token)
        refute Enum.any?(Map.values(env), &(&1 =~ "AUTHORIZATION")), inspect(token)
      end
    end
  end
end
