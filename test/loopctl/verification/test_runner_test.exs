defmodule Loopctl.Verification.TestRunnerTest do
  @moduledoc """
  Input hardening for the L3 verification runner — advisories ie-04
  (GHSA-pv74-gwwh-g92x) and ie-03 (GHSA-38cj-97f6-r82q).

  These tests exercise the validation helpers directly and assert that
  `run_tests/2` refuses hostile input BEFORE it can spawn `git`/`mix` or run
  `File.rm_rf/1`.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Verification.TestRunner

  describe "safe_repo_url?/1" do
    test "accepts http(s) URLs with a real host" do
      assert TestRunner.safe_repo_url?("https://github.com/acme/app.git")
      assert TestRunner.safe_repo_url?("http://example.com/repo.git")
      assert TestRunner.safe_repo_url?("HTTPS://github.com/acme/app.git")
    end

    test "rejects remote-helper / file / ssh / local-path / flag-shaped forms" do
      refute TestRunner.safe_repo_url?("ext::sh -c 'touch /tmp/pwned'")
      refute TestRunner.safe_repo_url?("file:///etc/passwd")
      refute TestRunner.safe_repo_url?("ssh://git@github.com/acme/app.git")
      refute TestRunner.safe_repo_url?("git@github.com:acme/app.git")
      refute TestRunner.safe_repo_url?("/etc/passwd")
      refute TestRunner.safe_repo_url?("-oProxyCommand=evil")
      refute TestRunner.safe_repo_url?("https://")
      refute TestRunner.safe_repo_url?(nil)
      refute TestRunner.safe_repo_url?(123)
    end
  end

  describe "build_work_dir/0 and within_tmp?/1 (path fencing)" do
    test "build_work_dir is unique and always inside the system temp dir" do
      dir1 = TestRunner.build_work_dir()
      dir2 = TestRunner.build_work_dir()

      assert dir1 != dir2
      assert TestRunner.within_tmp?(dir1)
      assert TestRunner.within_tmp?(dir2)
      assert String.starts_with?(Path.basename(dir1), "loopctl_verify_")
    end

    test "within_tmp? rejects traversal and outside-tmp paths" do
      tmp = System.tmp_dir!()

      refute TestRunner.within_tmp?(Path.join(tmp, "../../etc"))
      refute TestRunner.within_tmp?("/etc")
      refute TestRunner.within_tmp?("/")
      # the temp dir itself must never be a deletion target
      refute TestRunner.within_tmp?(tmp)
      refute TestRunner.within_tmp?(nil)
    end

    test "a hostile SHA-shaped value can never produce a work_dir outside tmp" do
      # work_dir is no longer derived from the SHA at all, so even an oversized /
      # traversal-shaped value can't influence the path — every build stays in tmp.
      Enum.each(1..50, fn _ ->
        assert TestRunner.within_tmp?(TestRunner.build_work_dir())
      end)
    end
  end

  describe "run_tests/2 refuses invalid input before spawning a subprocess" do
    @valid_sha String.duplicate("a", 40)
    @valid_url "https://github.com/acme/app.git"

    test "returns :invalid_commit_sha for a traversal SHA" do
      assert {:error, :invalid_commit_sha} =
               TestRunner.run_tests(@valid_url, "../../etc")
    end

    test "returns :invalid_commit_sha for a flag-shaped SHA" do
      assert {:error, :invalid_commit_sha} = TestRunner.run_tests(@valid_url, "-o=x")
    end

    test "returns :invalid_commit_sha for a blank SHA" do
      assert {:error, :invalid_commit_sha} = TestRunner.run_tests(@valid_url, "")
    end

    test "returns :invalid_repo_url for an ext:: remote-helper URL" do
      assert {:error, :invalid_repo_url} =
               TestRunner.run_tests("ext::sh -c 'id'", @valid_sha)
    end

    test "returns :invalid_repo_url for a file:// URL" do
      assert {:error, :invalid_repo_url} =
               TestRunner.run_tests("file:///etc/passwd", @valid_sha)
    end

    test "returns :invalid_repo_url for a bare local path" do
      assert {:error, :invalid_repo_url} = TestRunner.run_tests("/tmp/evil", @valid_sha)
    end
  end
end
