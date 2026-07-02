defmodule Loopctl.Verification.VerificationRunTest do
  @moduledoc """
  commit_sha validation — advisory ie-04 (GHSA-pv74-gwwh-g92x).

  A hex-only git object id cannot contain `/`, `..`, or a leading `-`, which
  closes the path-traversal and `git checkout` argument-injection vectors before
  the value ever reaches `Loopctl.Verification.TestRunner`.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Verification.VerificationRun

  setup :verify_on_exit!

  describe "changeset/2 commit_sha validation" do
    test "accepts a full SHA-1 (40 hex)" do
      sha = String.duplicate("a", 40)
      changeset = VerificationRun.changeset(%{commit_sha: sha})

      assert changeset.valid?
      assert get_change(changeset, :commit_sha) == sha
    end

    test "accepts a full SHA-256 (64 hex)" do
      sha = String.duplicate("0", 60) <> "beef"
      assert VerificationRun.changeset(%{commit_sha: sha}).valid?
    end

    test "accepts an abbreviated 7-hex SHA" do
      assert VerificationRun.changeset(%{commit_sha: "deadbee"}).valid?
    end

    test "rejects a path-traversal value" do
      changeset = VerificationRun.changeset(%{commit_sha: "../../etc"})

      refute changeset.valid?
      assert %{commit_sha: [_ | _]} = errors_on(changeset)
    end

    test "rejects a flag-shaped value" do
      refute VerificationRun.changeset(%{commit_sha: "-o=x"}).valid?
    end

    test "rejects a non-hex value" do
      refute VerificationRun.changeset(%{commit_sha: "deadbeefZZ"}).valid?
    end

    test "rejects an uppercase-hex value" do
      refute VerificationRun.changeset(%{commit_sha: String.duplicate("A", 40)}).valid?
    end

    test "rejects a too-short (6 hex) value" do
      refute VerificationRun.changeset(%{commit_sha: "abc123"}).valid?
    end

    test "rejects an oversized (65 hex) value" do
      refute VerificationRun.changeset(%{commit_sha: String.duplicate("a", 65)}).valid?
    end

    test "rejects an explicitly blank commit_sha" do
      changeset = VerificationRun.changeset(%{commit_sha: ""})

      refute changeset.valid?
      assert %{commit_sha: [_ | _]} = errors_on(changeset)
    end

    test "allows an absent commit_sha (run created before a commit exists)" do
      assert VerificationRun.changeset(%{status: "pending"}).valid?
    end

    test "allows an explicit nil commit_sha" do
      assert VerificationRun.changeset(%{commit_sha: nil, status: "pending"}).valid?
    end
  end

  describe "valid_commit_sha?/1" do
    test "true only for lowercase hex, 7-64 chars" do
      assert VerificationRun.valid_commit_sha?(String.duplicate("a", 40))
      assert VerificationRun.valid_commit_sha?(String.duplicate("f", 64))
      assert VerificationRun.valid_commit_sha?("deadbee")
    end

    test "false for traversal, flag, blank, non-binary and out-of-range values" do
      refute VerificationRun.valid_commit_sha?("../../etc")
      refute VerificationRun.valid_commit_sha?("-o=x")
      refute VerificationRun.valid_commit_sha?("deadbeefZZ")
      refute VerificationRun.valid_commit_sha?("")
      refute VerificationRun.valid_commit_sha?("abc123")
      refute VerificationRun.valid_commit_sha?(String.duplicate("a", 65))
      refute VerificationRun.valid_commit_sha?(nil)
      refute VerificationRun.valid_commit_sha?(:not_a_string)
    end
  end
end
