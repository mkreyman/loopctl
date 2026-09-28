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

      # A bare tenant UUID licenses no repository at all.
      bare = "0000a110-0000-4000-8000-00000000c330"

      for repo <- ["acme/widgets", ""],
          do: assert(OperatorCredential.for_read(bare, repo) == {:error, :credential_unavailable})
    end
  end

  # Round 2, finding 9: the worker asks this before any read of the story.
  describe "OperatorCredential.any_for_tenant?/1" do
    test "a tenant named in a well-formed entry, for any repository, trimmed and in any case" do
      assert OperatorCredential.any_for_tenant?(@named)
      assert OperatorCredential.any_for_tenant?(@named_padded)
      assert OperatorCredential.any_for_tenant?(String.upcase(@named))
    end

    test "a tenant named nowhere, or only in a malformed entry, is not" do
      refute OperatorCredential.any_for_tenant?(Ecto.UUID.generate())
      refute OperatorCredential.any_for_tenant?("0000a110-0000-4000-8000-00000000c330")
      refute OperatorCredential.any_for_tenant?("0000a110-0000-4000-8000-00000000d440")
      refute OperatorCredential.any_for_tenant?("not-a-uuid")
      refute OperatorCredential.any_for_tenant?(nil)
    end
  end
end
