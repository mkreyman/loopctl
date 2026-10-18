defmodule ChgAdapter.HeadTest do
  use ExUnit.Case, async: false

  # Variables that would steer git or head!/0 from outside the test: a git hook exports
  # GIT_DIR, a sandbox may set a ceiling.
  @vars ~w(CHG_SHA GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_CEILING_DIRECTORIES)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    root = Path.join(System.tmp_dir!(), "chg-head-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    plain = Path.join(root, "plain")
    File.mkdir_p!(repo)
    File.mkdir_p!(plain)

    on_exit(fn ->
      File.rm_rf!(root)

      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    git = fn args ->
      {out, 0} =
        System.cmd(
          "git",
          ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" | args],
          cd: repo,
          stderr_to_stdout: true
        )

      String.trim(out)
    end

    git.(["init", "-q"])
    git.(["commit", "-q", "--allow-empty", "-m", "one"])
    # The temp dir may sit inside a checkout; the ceiling keeps git from finding it.
    System.put_env("GIT_CEILING_DIRECTORIES", root)
    %{repo: repo, plain: plain, sha: git.(["rev-parse", "HEAD"])}
  end

  test "CHG_SHA names the commit of a tree with no .git", %{plain: plain} do
    System.put_env("CHG_SHA", "0123456789abcdef0123456789abcdef01234567")

    File.cd!(plain, fn ->
      assert ChgAdapter.head!() == "0123456789abcdef0123456789abcdef01234567"
    end)
  end

  test "without CHG_SHA, git answers in a checkout", %{repo: repo, sha: sha} do
    File.cd!(repo, fn -> assert ChgAdapter.head!() == sha end)
  end

  test "without CHG_SHA, a tree with no .git is an error", %{plain: plain} do
    File.cd!(plain, fn ->
      assert_raise Mix.Error, ~r/not a git repository/, fn -> ChgAdapter.head!() end
    end)
  end
end
