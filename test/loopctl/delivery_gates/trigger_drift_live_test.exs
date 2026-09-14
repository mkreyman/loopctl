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

  **Two bounds on artifact mode, stated rather than left to be discovered.**

  It cannot see a rename that happened AFTER the artifact was written. It makes a committed
  drifted artifact red and a missing one red; it does not make a STALE one red, because a
  staleness deadline would fail builds on quiet weeks for a reason unrelated to drift.

  And it says nothing about WHICH document is live. The artifact's `meta.trigger_fingerprint`
  names the document the check ran against, and while a corrected document is written but not
  yet imported that is not the one production is running — so a green build here is green over
  a configuration in a file, not over the gate as deployed. Nothing in this repository can
  close that: the live document is a secret and loopctl's CI cannot read it. Compare the
  fingerprint on the artifact against the running release before reading a green build as a
  statement about production.

  Closing either needs the check to run where the tree and the live document are — the target
  repository's own CI, or a scheduled check in production reading the tree through the GitHub
  API — and both are named in this change's pull request as follow-on work.

  Half-configured is a failure, not a fall-back to artifact mode: ANY one of the three variables
  set means live mode, so a shell profile or a runner environment that carries only one of them
  gets a refusal rather than the weaker assertion run silently in its place.
  """

  alias Loopctl.DeliveryGates.TriggerDrift
  alias Loopctl.DeliveryGates.Triggers
  alias Mix.Tasks.Loopctl.Gates.CheckDrift

  @artifact "docs/measurements/trigger_drift.json"

  @repo_var "LOOPCTL_TRIGGER_DRIFT_REPO"
  @document_var "LOOPCTL_TRIGGER_DRIFT_DOCUMENT"
  @repo_name_var "LOOPCTL_TRIGGER_DRIFT_REPO_NAME"

  describe "every configured pattern still matches a file in the target repository" do
    test "live, or over the committed artifact" do
      {repo, document, repo_name} = env = configured_env()

      case mode(env) do
        :artifact -> assert_artifact_clean()
        :live -> assert_live_clean(repo, document, repo_name)
      end
    end
  end

  describe "mode/1" do
    # The dispatch is a pure function so every combination is asserted here rather than being
    # reachable only by exporting a variable and running the suite by hand. It used to read two
    # of the three, so a machine carrying only LOOPCTL_TRIGGER_DRIFT_REPO_NAME — a shell
    # profile, a runner environment — fell into the artifact branch and ran the weaker
    # assertion with nobody told.
    test "only a completely unset environment is artifact mode" do
      assert mode({nil, nil, nil}) == :artifact
    end

    test "ANY one of the three set is live mode, so the refusals below fire" do
      for env <- [
            {"/repo", nil, nil},
            {nil, "/doc.json", nil},
            {nil, nil, "owner/repo"},
            {"/repo", "/doc.json", nil},
            {"/repo", nil, "owner/repo"},
            {nil, "/doc.json", "owner/repo"},
            {"/repo", "/doc.json", "owner/repo"}
          ] do
        assert mode(env) == :live, "#{inspect(env)} must not fall back to the artifact"
      end
    end
  end

  defp configured_env do
    {System.get_env(@repo_var), System.get_env(@document_var), System.get_env(@repo_name_var)}
  end

  # ANY of the three means live. A partially configured environment reaches `assert_live_clean/3`
  # and is REFUSED there by name, which is the whole point: somebody meant to run the real
  # assertion, and silently running the weaker one in its place is the failure.
  defp mode({nil, nil, nil}), do: :artifact
  defp mode({_repo, _document, _repo_name}), do: :live

  # -- live -------------------------------------------------------------------------------

  defp assert_live_clean(repo, document, repo_name) do
    refute is_nil(repo), "#{@repo_var} is not set — refusing to fall back to the artifact"

    refute is_nil(document),
           "#{@document_var} is not set — refusing to fall back to the artifact"

    refute is_nil(repo_name),
           "#{@repo_name_var} must name the owner/repo key the trigger document uses"

    repo_triggers = live_repo_triggers(document, repo_name)
    files = live_files(repo)

    case TriggerDrift.unmatched(repo_triggers, files) do
      {:ok, []} ->
        :ok

      {:ok, drifted} ->
        # The patterns are the guard map. Count and kind only, even in a failure message: a
        # CI log is as public as a committed artifact.
        # Counts and kinds only, and NOT the checkout path or the tree's size: those are
        # `:checkout` and `:tree_files`, the two keys this change deleted from the artifact on
        # the stated rule that a CI log is as public as a committed artifact. The line above
        # already withholds the pattern text; withholding one and printing the others was
        # incoherent.
        flunk("""
        #{length(drifted)} configured pattern(s) match nothing in the target repository.

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
        {:ok, document} ->
          document

        # The variable's NAME, never its value: the value is a local absolute path to the
        # trigger document, and this message lands in the same log as the others.
        {:error, reason} ->
          flunk(
            "cannot read the document named by #{@document_var}: #{:file.format_error(reason)}"
          )
      end

    sha = :sha256 |> :crypto.hash(document) |> Base.encode16(case: :lower)

    parsed =
      case Triggers.parse(document, sha) do
        {:ok, parsed} ->
          parsed

        # Reduced, never inspected: the full reason names the offending glob, and live mode
        # runs on the runner, whose log is as public as a committed artifact.
        {:error, reason} ->
          flunk("the trigger document did not parse: #{TriggerDrift.describe_error(reason)}")
      end

    case Triggers.fetch_repo(parsed, repo_name) do
      {:ok, repo_triggers} -> repo_triggers
      :error -> flunk("the trigger document does not name #{repo_name}")
    end
  end

  # Two things this call must get right, and it got only one of them for a round.
  #
  # stderr is never merged into stdout: `ls-tree -z` separates paths with NUL, a git advisory
  # carries none, so a merged warning is glued onto the first path and that path silently stops
  # matching any pattern.
  #
  # And the ENVIRONMENT is scrubbed, from the same one list everything else here uses. Without
  # it this was the very defect this change exists to close, in LIVE mode: `mix test` is run by
  # the quality gate from inside the pre-commit hook, the hook exports GIT_DIR, and GIT_DIR beats
  # `-C`. The drift assertion would then be computed against loopctl's own file list — patterns
  # that happen to match a loopctl path reporting alive, the rest reporting a drift that does not
  # exist — so the runner's green and its red would both say nothing about the target repository.
  defp live_files(repo) do
    files =
      case System.cmd("git", ["-C", repo, "ls-tree", "-r", "--name-only", "-z", "HEAD"],
             stderr_to_stdout: false,
             env: CheckDrift.git_env()
           ) do
        {output, 0} ->
          String.split(output, <<0>>, trim: true)

        {_output, status} ->
          flunk("git ls-tree exited #{status} — git's own diagnostic is on stderr")
      end

    refute files == [], "the target repository lists no files — refusing a vacuous pass"

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

    assert_redacted(artifact)
  end

  # The redaction §13 requires: a committed artifact says whether each guard is alive, never
  # what it guards, how broadly, or anything about the machine that checked it.
  #
  # Asserted over the WHOLE artifact and not only over the pattern rows, because the first leak
  # was in `meta` — an absolute local checkout path and the private repository's file count —
  # where a row-shaped assertion could never have seen it.
  defp assert_redacted(artifact) do
    meta = artifact["meta"] || %{}

    # EQUALITY, not a deny list. Refuting three known-bad keys is the polarity this change just
    # replaced in the code, and leaving it here left the only artifact that actually ships
    # unguarded against a key nobody thought of — a branch name, a document filename, a
    # hostname, a tree_bytes count would all have passed.
    #
    # The six are written out literally rather than read from
    # `CheckDrift.published_meta_keys/0`: a test that derives its expectation from the list it
    # is checking moves with any change to that list and can never go red when one widens.
    assert Enum.sort(Map.keys(meta)) == [
             "generated_at",
             "harness",
             "head",
             "repo",
             "trigger_checksum_source",
             "trigger_fingerprint"
           ],
           "the committed artifact's meta is not exactly the six published keys"

    for row <- artifact["patterns"], key <- ~w(pattern matches) do
      refute Map.has_key?(row, key), "the committed artifact leaks #{key}"
    end

    encoded = Jason.encode!(artifact)

    # Shape-based, so it catches a leak under a key nobody thought to name above.
    for {label, needle} <- [
          {"an absolute home path", "/home/"},
          {"an absolute macOS home path", "/Users/"},
          {"an Elixir source path", ".ex"},
          {"a glob pattern", "**"}
        ] do
      refute String.contains?(encoded, needle),
             "the committed artifact contains #{label} (#{inspect(needle)})"
    end
  end
end
