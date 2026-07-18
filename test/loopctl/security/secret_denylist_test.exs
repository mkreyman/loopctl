defmodule Loopctl.Security.SecretDenylistTest do
  use ExUnit.Case, async: true

  alias Loopctl.Security.SecretDenylist

  describe "contains_secret?/1" do
    test "flags each denylisted credential shape" do
      secrets = [
        "Authorization: Bearer " <> String.duplicate("a", 30),
        "sk-" <> String.duplicate("a", 30),
        "lc_" <> String.duplicate("a", 30),
        "ghp_" <> String.duplicate("a", 30),
        "github_pat_" <> String.duplicate("a", 30),
        "AKIA" <> String.duplicate("A", 16),
        "-----BEGIN RSA PRIVATE KEY-----",
        "xoxb-" <> String.duplicate("a", 20),
        # Stripe secret / restricted keys (underscore prefix, not sk-)
        "sk_live_" <> String.duplicate("a", 24),
        "sk_test_" <> String.duplicate("a", 24),
        "rk_live_" <> String.duplicate("a", 24),
        # JWT (header.payload.signature). Assembled at runtime, NOT written as a
        # contiguous literal, so no scannable secret-shaped string lands in
        # source — this is what keeps GitGuardian (which scans source literals)
        # from flagging these intentional denylist fixtures. Do NOT "simplify"
        # these back into full string literals; that re-breaks the secret scan.
        "eyJ" <>
          String.duplicate("a", 20) <>
          "." <> String.duplicate("b", 20) <> "." <> String.duplicate("c", 20),
        # URL-embedded credentials
        "DATABASE_URL=postgres://user:s3cretpw@db.internal:5432/app",
        "clone https://mark:" <> String.duplicate("z", 12) <> "@github.com/acme/repo"
      ]

      for s <- secrets do
        assert SecretDenylist.contains_secret?(s), "expected a secret match in: #{s}"
      end
    end

    test "does not flag ordinary coordination chatter" do
      clean = [
        "pushed PR #107, CI green",
        "reviewing epic 39 on branch epic-39-us-39.1",
        "found a race in the sweep worker",
        "sk-too-short",
        nil,
        %{"not" => "a string"}
      ]

      for c <- clean do
        refute SecretDenylist.contains_secret?(c), "unexpected secret match in: #{inspect(c)}"
      end
    end
  end

  describe "any_contains_secret?/1" do
    test "true when any member matches, ignoring non-binaries" do
      assert SecretDenylist.any_contains_secret?([
               nil,
               "clean",
               "sk-" <> String.duplicate("a", 30)
             ])

      refute SecretDenylist.any_contains_secret?([nil, "clean", 42, %{}])
    end
  end
end
