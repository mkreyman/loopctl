defmodule Loopctl.DeliveryGates.TriggerDriftLiveTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The drift assertion design §5 specifies: every configured Gate B pattern must match at least
  one file in the target repository, and this goes red when one stops.

  ## Two modes, and why there are two rather than one

  Both of the assertion's inputs are deliberately absent from this repository. The target
  repository is PRIVATE, and the trigger document is a secret because it is a map of which
  paths skip human review (design §13). So there is no configuration in which loopctl's own CI
  can read the live tree, and the assertion runs in whichever mode its inputs allow:

  - **live** — `LOOPCTL_TRIGGER_DRIFT_REPO` names a checkout and
    `LOOPCTL_TRIGGER_DRIFT_DOCUMENT` a trigger document. The real assertion: read the tree, run
    the same checker the gate runs, fail on any unmatched pattern. This is the mode that turns a
    rename into a red build, and it runs where both inputs exist — a dev machine or a runner.
  - **artifact** — neither is set. Assert over the committed
    `docs/measurements/trigger_drift.json`, which `mix loopctl.gates.check_drift` writes: it must
    be present, well-formed, redacted, and report zero unmatched patterns.

  **The bound, stated rather than left to be discovered:** artifact mode cannot see a rename
  that happened after the artifact was written. It makes a committed drifted artifact red and a
  missing one red; it does not make a stale one red, because a staleness deadline would fail
  builds on quiet weeks for a reason unrelated to drift. Closing that needs the check to run
  where the tree is — home_care_billing's own CI, or a scheduled check reading the tree through
  the GitHub API — and both are named in this change's pull request as follow-on work.

  Half-configured is a failure, not a fall-back to artifact mode: one variable set and the other
  absent means somebody meant to run the real assertion and it silently did not.
  """

  alias Loopctl.DeliveryGates.TriggerDrift
  alias Loopctl.DeliveryGates.Triggers

  @artifact "docs/measurements/trigger_drift.json"

  @repo_var "LOOPCTL_TRIGGER_DRIFT_REPO"
  @document_var "LOOPCTL_TRIGGER_DRIFT_DOCUMENT"
  @repo_name_var "LOOPCTL_TRIGGER_DRIFT_REPO_NAME"

  describe "every configured pattern still matches a file in the target repository" do
    test "live, or over the committed artifact" do
      case {System.get_env(@repo_var), System.get_env(@document_var)} do
        {nil, nil} -> assert_artifact_clean()
        {repo, document} -> assert_live_clean(repo, document)
      end
    end
  end

  # -- live -------------------------------------------------------------------------------

  defp assert_live_clean(repo, document) do
    refute is_nil(repo),
           "#{@document_var} is set and #{@repo_var} is not — refusing to fall back to the artifact"

    refute is_nil(document),
           "#{@repo_var} is set and #{@document_var} is not — refusing to fall back to the artifact"

    repo_name =
      System.get_env(@repo_name_var) ||
        flunk("#{@repo_name_var} must name the owner/repo key the trigger document uses")

    repo_triggers = live_repo_triggers(document, repo_name)
    files = live_files(repo)

    case TriggerDrift.unmatched(repo_triggers, files) do
      {:ok, []} ->
        :ok

      {:ok, drifted} ->
        # The patterns are the guard map. Count and kind only, even in a failure message: a
        # CI log is as public as a committed artifact.
        flunk("""
        #{length(drifted)} configured pattern(s) match nothing in #{repo_name} \
        (#{length(files)} files read from #{repo}).

        Each has stopped guarding the path it names. Run
        `mix loopctl.gates.check_drift` for the unredacted list, which it writes outside
        this repository.
        """)

      {:error, reason} ->
        flunk(
          "the drift check refused: #{inspect(reason)} — a checker that cannot read the tree proves nothing"
        )
    end
  end

  defp live_repo_triggers(path, repo_name) do
    document =
      case File.read(path) do
        {:ok, document} -> document
        {:error, reason} -> flunk("cannot read #{path}: #{:file.format_error(reason)}")
      end

    sha = :sha256 |> :crypto.hash(document) |> Base.encode16(case: :lower)

    parsed =
      case Triggers.parse(document, sha) do
        {:ok, parsed} -> parsed
        {:error, reason} -> flunk("the trigger document did not parse: #{inspect(reason)}")
      end

    case Triggers.fetch_repo(parsed, repo_name) do
      {:ok, repo_triggers} -> repo_triggers
      :error -> flunk("the trigger document does not name #{repo_name}")
    end
  end

  defp live_files(repo) do
    files =
      case System.cmd("git", ["-C", repo, "ls-tree", "-r", "--name-only", "-z", "HEAD"],
             stderr_to_stdout: true
           ) do
        {output, 0} -> String.split(output, <<0>>, trim: true)
        {output, status} -> flunk("git ls-tree in #{repo} exited #{status}: #{output}")
      end

    refute files == [], "#{repo} lists no files — refusing a vacuous pass"

    files
  end

  # -- artifact ---------------------------------------------------------------------------

  defp assert_artifact_clean do
    artifact =
      case File.read(@artifact) do
        {:ok, contents} ->
          Jason.decode!(contents)

        {:error, reason} ->
          flunk("""
          #{@artifact} is missing (#{:file.format_error(reason)}).

          It is this repository's only standing evidence that the Gate B trigger patterns still
          match anything. Regenerate it with `mix loopctl.gates.check_drift`.
          """)
      end

    assert artifact["check"] == "gate_b_trigger_drift"

    patterns = artifact["patterns"]
    assert is_list(patterns) and patterns != [], "the artifact reports no patterns at all"

    assert artifact["totals"]["patterns"] == length(patterns)

    # Every row must STATE its verdict. A row missing `matched` is not a pass: an artifact
    # written by something that did not answer the question is the vacuous pass this exists to
    # prevent.
    assert Enum.all?(patterns, &is_boolean(&1["matched"])),
           "a pattern row does not state whether it matched"

    drifted = Enum.reject(patterns, & &1["matched"])

    assert drifted == [],
           "#{length(drifted)} configured pattern(s) matched nothing when the artifact was written"

    assert artifact["totals"]["unmatched"] == 0

    # The redaction §13 requires: a committed artifact says whether each guard is alive, never
    # what it guards nor how broadly.
    assert Enum.all?(patterns, &(not Map.has_key?(&1, "pattern"))),
           "the committed artifact leaks trigger patterns"

    assert Enum.all?(patterns, &(not Map.has_key?(&1, "matches"))),
           "the committed artifact leaks per-pattern match counts"
  end
end
