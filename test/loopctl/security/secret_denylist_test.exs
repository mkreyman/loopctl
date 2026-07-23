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
        # URL-embedded credentials. Same runtime-assembly rule as the JWT above:
        # never let a contiguous scheme://user:pass@ literal land in source, or
        # GitGuardian flags these intentional fixtures as real credentials.
        "DATABASE_URL=postgres://user:" <> String.duplicate("z", 8) <> "@db.internal:5432/app",
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

  describe "revision/0 <-> pattern-set binding (issue #499)" do
    # The pattern set as of the DECLARED revision below. Derived mechanically from the
    # regex sources by `SecretDenylist.fingerprint/0`.
    @declared_fingerprint 115_481_899
    @declared_revision ~U[2026-07-22 00:00:00Z]

    # THIS TEST IS THE MECHANICAL LINK between the pattern set and the retroactivity
    # lever. The rescan worker (issue #499) re-examines an already-scanned post ONLY
    # when `rescanned_at < revision/0`, so a commit that adds or loosens a credential
    # shape WITHOUT bumping @revision ships a write-time-only pattern: the retroactive
    # sweep never happens, and telemetry still reports healthy zero-hit runs — there is
    # no runtime signal separating "nothing to find" from "retroactivity disabled".
    # A code comment cannot enforce that. This assertion can.
    test "the pattern set has not changed since the declared revision" do
      assert SecretDenylist.fingerprint() == @declared_fingerprint, """
      The secret denylist pattern set CHANGED.

      Because retroactive rescanning keys off SecretDenylist.revision/0, a pattern edit
      without a revision bump silently applies to NEW writes only — every post written
      before the deploy is never re-examined (issue #499).

      In THIS commit:
        1. bump @revision in lib/loopctl/security/secret_denylist.ex to the current
           UTC instant (rounded to the second), and
        2. update @declared_fingerprint / @declared_revision in this test to
           #{SecretDenylist.fingerprint()} and the same instant.
      """

      assert SecretDenylist.revision() == @declared_revision
    end
  end
end
