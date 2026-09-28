defmodule Loopctl.Verification.CredentialTest do
  @moduledoc """
  US-26.4.6, AC-26.4.6.8: the operator's `GITHUB_TOKEN` is lent only for the (tenant,
  repository) PAIRS the operator named. `config/test.exs` names two well-formed pairs (one
  padded and in mixed case) and three malformed entries; no fixture ever creates a tenant with
  any of those ids.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Verification.Credential
  alias Loopctl.Verification.OperatorCredential

  @named "0000a110-0000-4000-8000-00000000a110"
  @named_padded "0000a110-0000-4000-8000-00000000b220"

  describe "OperatorCredential.for_read/2" do
    test "a named pair gets the operator credential" do
      assert {:ok, %Credential{kind: :operator_token}} =
               OperatorCredential.for_read(@named, "acme/widgets")
    end

    test "both halves match trimmed and case-insensitively" do
      assert {:ok, %Credential{}} = OperatorCredential.for_read(@named_padded, "acme/gadgets")
      assert {:ok, %Credential{}} = OperatorCredential.for_read(@named_padded, "ACME/Gadgets")

      assert {:ok, %Credential{}} =
               OperatorCredential.for_read(String.upcase(@named), "Acme/Widgets")
    end

    test "a named tenant has no credential for a repository it was not named with" do
      # Allowlisted for acme/widgets, enrolling acme/gadgets (another tenant's pair) or any
      # other repository: nothing is read.
      assert OperatorCredential.for_read(@named, "acme/gadgets") ==
               {:error, :credential_unavailable}

      assert OperatorCredential.for_read(@named, "evil/private") ==
               {:error, :credential_unavailable}
    end

    test "TC-26.4.6.6 any other tenant has no credential" do
      assert OperatorCredential.for_read(Ecto.UUID.generate(), "acme/widgets") ==
               {:error, :credential_unavailable}

      assert OperatorCredential.for_read("not-a-uuid", "acme/widgets") ==
               {:error, :credential_unavailable}

      assert OperatorCredential.for_read(nil, "acme/widgets") ==
               {:error, :credential_unavailable}

      assert OperatorCredential.for_read(@named, nil) == {:error, :credential_unavailable}
    end

    test "a malformed entry is dropped: no repository, a bad repository, a bad tenant" do
      assert Enum.sort(OperatorCredential.allowlist()) ==
               Enum.sort([{@named, "acme/widgets"}, {@named_padded, "acme/gadgets"}])

      # The bare-UUID entry (the old format) licenses no repository at all.
      bare = "0000a110-0000-4000-8000-00000000c330"

      for repo <- ["acme/widgets", ""],
          do: assert(OperatorCredential.for_read(bare, repo) == {:error, :credential_unavailable})
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
