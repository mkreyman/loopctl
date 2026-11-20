defmodule Loopctl.ReleaseRetireRepoTest do
  @moduledoc """
  TC-52.11.1..4 (US-52.11): `release/retire-repo.sh` against a stubbed gh whose state lives
  in files, a stub import, and a throwaway repository holding `release/imports.toml`; and
  `release/lib/drop_retired_sources.py` against a sample `~/.chg/loopctl.toml`.
  """
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates.GitEnv

  @script Path.expand("../../release/retire-repo.sh", __DIR__)
  @drop Path.expand("../../release/lib/drop_retired_sources.py", __DIR__)

  # Open issues, PRs and the archived flag are files under $STUB; every write is logged.
  @gh """
  #!/usr/bin/env bash
  case "$1 $2" in
    "issue list") cat "$STUB/issues" 2>/dev/null || true ;;
    "repo view") [ -f "$STUB/archived" ] && echo true || echo false ;;
    "pr list") cat "$STUB/prs" 2>/dev/null || true ;;
    "label create") echo "label $*" >> "$STUB/writes" ;;
    "issue edit") echo "edit $3" >> "$STUB/writes" ;;
    "issue transfer")
      echo "transfer $3 $4" >> "$STUB/writes"
      [ "$3" = "$(cat "$STUB/fail_transfer" 2>/dev/null)" ] && exit 1
      grep -vx "$3" "$STUB/issues" > "$STUB/issues.new"; mv "$STUB/issues.new" "$STUB/issues" ;;
    "repo archive") echo "archive" >> "$STUB/writes"; touch "$STUB/archived" ;;
  esac
  """

  @import """
  #!/usr/bin/env bash
  echo "import $1 $2" >> "$STUB/writes"
  """

  @imports_toml """
  # Which source commit each imported prefix holds (release/import-history.sh).

  [[import]]
  repo = "mkreyman/loopctl-runner"
  prefix = "runner"
  imported_sha = "e7c7f6dc815a1f1389446da7dfaf2fee4696cc87"

  [[import]]
  repo = "mkreyman/chg"
  prefix = "chg"
  imported_sha = "7bbc5dc111b24a08742e6dc6fadd203d6b6b7c69"
  """

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    stub = Path.join(tmp, "stub")
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(stub)
    File.mkdir_p!(Path.join(repo, "release"))
    File.write!(Path.join([repo, "release", "imports.toml"]), @imports_toml)
    git!(repo, ["init", "-q", "-b", "master"])
    git!(repo, ["add", "release/imports.toml"])
    git!(repo, ["commit", "-q", "-m", "init"])

    exec!(Path.join(stub, "gh"), @gh)
    exec!(Path.join(stub, "import"), @import)
    stories = Path.join(tmp, "stories.json")
    File.write!(stories, Jason.encode!(%{"data" => []}))

    env =
      GitEnv.spawn_env() ++
        [
          {"STUB", stub},
          {"RETIRE_GH", Path.join(stub, "gh")},
          {"RETIRE_IMPORT", Path.join(stub, "import")},
          {"GIT_AUTHOR_NAME", "t"},
          {"GIT_AUTHOR_EMAIL", "t@t"},
          {"GIT_COMMITTER_NAME", "t"},
          {"GIT_COMMITTER_EMAIL", "t@t"}
        ]

    %{stub: stub, repo: repo, stories: stories, env: env}
  end

  describe "TC-52.11.1: refuses with blockers, then transfers and archives, then is a no-op" do
    test "an open pull request refuses with exit 2 and writes nothing", ctx do
      File.write!(Path.join(ctx.stub, "prs"), "7\n")
      File.write!(Path.join(ctx.stub, "issues"), "3\n")

      {out, 2} = retire(ctx)
      assert out =~ "open pull request #7"
      refute File.exists?(Path.join(ctx.stub, "writes"))
    end

    test "labels, transfers, archives, imports and marks the entry", ctx do
      File.write!(Path.join(ctx.stub, "issues"), "3\n5\n")

      {out, 0} = retire(ctx)
      assert out =~ "retired: mkreyman/chg"

      writes = writes(ctx)
      assert "edit 3" in writes and "transfer 3 mkreyman/loopctl" in writes
      assert "transfer 5 mkreyman/loopctl" in writes

      assert Enum.find_index(writes, &(&1 == "edit 3")) <
               Enum.find_index(writes, &(&1 == "transfer 3 mkreyman/loopctl"))

      assert Enum.find_index(writes, &(&1 == "transfer 5 mkreyman/loopctl")) <
               Enum.find_index(writes, &(&1 == "archive"))

      assert Enum.find_index(writes, &(&1 == "archive")) <
               Enum.find_index(writes, &String.starts_with?(&1, "import"))

      assert "import git@github.com:mkreyman/chg.git chg" in writes
      assert Enum.any?(writes, &(&1 =~ "label label create from:chg -R mkreyman/loopctl"))

      toml = File.read!(Path.join([ctx.repo, "release", "imports.toml"]))

      assert toml =~
               ~s(repo = "mkreyman/chg"\nprefix = "chg"\nimported_sha = "7bbc5dc111b24a08742e6dc6fadd203d6b6b7c69"\narchived = true)

      refute toml =~ ~s(imported_sha = "e7c7f6dc815a1f1389446da7dfaf2fee4696cc87"\narchived)
      assert {"", 0} = System.cmd("git", ["status", "--porcelain"], cd: ctx.repo)
    end

    test "a retired repo makes no write and says so", ctx do
      {_, 0} = retire(ctx)
      File.rm!(Path.join(ctx.stub, "writes"))

      {out, 0} = retire(ctx)
      assert out =~ "retired: mkreyman/chg"
      refute File.exists?(Path.join(ctx.stub, "writes"))
    end

    test "a failed transfer leaves the repo unarchived; the next run finishes", ctx do
      File.write!(Path.join(ctx.stub, "issues"), "3\n5\n")
      File.write!(Path.join(ctx.stub, "fail_transfer"), "5")

      {out, 1} = retire(ctx)
      assert out =~ "mkreyman/chg#5 did not move"
      refute "archive" in writes(ctx)

      File.rm!(Path.join(ctx.stub, "fail_transfer"))
      assert {_, 0} = retire(ctx)
      assert "archive" in writes(ctx)
    end
  end

  describe "TC-52.11.2: an in-flight story blocks retirement" do
    for {agent, verified} <- [
          {"contracted", "unverified"},
          {"assigned", "unverified"},
          {"implementing", "unverified"},
          {"reported_done", "unverified"}
        ] do
      test "#{agent}/#{verified} blocks", ctx do
        File.write!(
          ctx.stories,
          Jason.encode!(%{
            "data" => [
              %{
                "id" => "s1",
                "number" => "4.2",
                "agent_status" => unquote(agent),
                "verified_status" => unquote(verified)
              }
            ]
          })
        )

        {out, 2} = retire(ctx)
        assert out =~ "story in flight: 4.2 s1"
      end
    end

    test "a verified or pending story does not block", ctx do
      File.write!(
        ctx.stories,
        Jason.encode!(%{
          "data" => [
            %{
              "id" => "a",
              "number" => "1",
              "agent_status" => "reported_done",
              "verified_status" => "verified"
            },
            %{
              "id" => "b",
              "number" => "2",
              "agent_status" => "pending",
              "verified_status" => "unverified"
            }
          ]
        })
      )

      assert {_, 0} = retire(ctx)
    end
  end

  describe "TC-52.11.3: the archived marker stops import-history" do
    test "an entry marked archived is refused before anything is read", ctx do
      {_, 0} = retire(ctx)
      head = rev(ctx.repo)

      {out, 2} =
        System.cmd(
          "bash",
          [Path.expand("../../release/import-history.sh", __DIR__), "/nonexistent/chg", "chg"],
          cd: ctx.repo,
          env: ctx.env,
          stderr_to_stdout: true
        )

      assert out =~ "chg/ is imported from"
      assert out =~ "which is archived"
      assert rev(ctx.repo) == head
    end

    test "an entry not marked archived is not refused for that reason", ctx do
      {out, _} =
        System.cmd(
          "bash",
          [Path.expand("../../release/import-history.sh", __DIR__), "/nonexistent/chg", "chg"],
          cd: ctx.repo,
          env: ctx.env,
          stderr_to_stdout: true
        )

      refute out =~ "archived"
    end

    defp rev(repo) do
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo, env: GitEnv.spawn_env())
      sha
    end
  end

  describe "TC-52.11.4: loopctl.toml cleanup keeps other sources" do
    @loopctl_toml """
    [[source]]
    repo = "mkreyman/chg"
    source_id = "7c2ca807"
    secret_file = "/s/chg"

    [[source]]
    repo = "mkreyman/ads_for_care"  # keep me
    source_id = "d90a1c62"
    secret_file = "/s/ads_for_care"

    [[source]]
    repo = "mkreyman/loopctl-runner"
    source_id = "23775166"
    secret_file = "/s/loopctl-runner"

    [[source]]
    repo = "mkreyman/reportex"
    source_id = "3fd6d7d5"
    secret_file = "/s/reportex"
    """

    test "removes only the retired repos' blocks, byte-identically elsewhere", %{tmp_dir: tmp} do
      {config, manifest} = drop_fixture(tmp)

      assert {"changed\n", 0} = System.cmd("python3", ["-I", @drop, config, manifest])

      assert File.read!(config) == """
             [[source]]
             repo = "mkreyman/ads_for_care"  # keep me
             source_id = "d90a1c62"
             secret_file = "/s/ads_for_care"

             [[source]]
             repo = "mkreyman/reportex"
             source_id = "3fd6d7d5"
             secret_file = "/s/reportex"
             """

      assert {"unchanged\n", 0} = System.cmd("python3", ["-I", @drop, config, manifest])
    end

    test "a file that is not TOML is refused and left alone", %{tmp_dir: tmp} do
      {config, manifest} = drop_fixture(tmp)
      File.write!(config, "[[source]\nrepo = \"mkreyman/chg\"\n")

      assert {_, 1} =
               System.cmd("python3", ["-I", @drop, config, manifest], stderr_to_stdout: true)

      assert File.read!(config) == "[[source]\nrepo = \"mkreyman/chg\"\n"
    end

    defp drop_fixture(tmp) do
      config = Path.join(tmp, "loopctl.toml")
      manifest = Path.join(tmp, "manifest.toml")
      File.write!(config, @loopctl_toml)

      File.write!(
        manifest,
        ~s(set = 2\n\n[retired]\nrepos = ["mkreyman/chg", "mkreyman/loopctl-runner"]\n)
      )

      {config, manifest}
    end
  end

  defp retire(ctx),
    do:
      System.cmd("bash", [@script, "mkreyman/chg", ctx.stories],
        cd: ctx.repo,
        env: ctx.env,
        stderr_to_stdout: true
      )

  defp writes(ctx) do
    case File.read(Path.join(ctx.stub, "writes")) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp exec!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp git!(dir, args) do
    {_, 0} =
      System.cmd("git", GitEnv.config_args() ++ args,
        cd: dir,
        env:
          GitEnv.spawn_env() ++
            [
              {"GIT_AUTHOR_NAME", "t"},
              {"GIT_AUTHOR_EMAIL", "t@t"},
              {"GIT_COMMITTER_NAME", "t"},
              {"GIT_COMMITTER_EMAIL", "t@t"}
            ],
        stderr_to_stdout: true
      )
  end
end
