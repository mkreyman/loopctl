defmodule Mix.Tasks.Loopctl.Gates.CheckDrift do
  @shortdoc "Assert every configured Gate B pattern still matches a file in the target repository"

  @moduledoc """
  The drift assertion design §5 specifies — "read literally off the repo and asserted by a test
  that fails when one stops existing" — run against a real checkout.

  A configured pattern that matches nothing has stopped guarding the path it names. At runtime
  that escalates as `{:stale_trigger, pattern}`, which is fail-closed but reads as one more
  escalation; run here it is what it is, a configuration alarm, and it exits non-zero.

  It reads the checkout READ-ONLY (`ls-tree` and `rev-parse` only — no fetch, no checkout), so
  it is safe to point at a tree somebody is working in. It writes nothing to the database and
  changes no gate.

  ## Usage

      mix loopctl.gates.check_drift \\
        --repo /path/to/checkout \\
        --repo-name owner/repo \\
        --triggers /path/to/triggers.json \\
        --out docs/measurements/trigger_drift.json

  ## Options

    * `--repo` (required) — path to the target repository's checkout.
    * `--repo-name` (required) — the `owner/repo` key the trigger document uses. Not inferred
      from the remote: the document is keyed by it, and inferring would let a differently-named
      remote be checked against another repository's trigger list.
    * `--triggers` (required) — path to the Gate B trigger JSON document. NOT committed and
      never printed: design §13 keeps it in configuration because loopctl is public and the
      document is a map of which paths skip human review.
    * `--sha256` — the checksum the OPERATOR pinned beside the document in production. Given,
      it is what `Loopctl.DeliveryGates.Triggers.parse/2` verifies against, and a local file
      whose bytes differ from the pinned ones fails the run naming the trailing-newline trap.
      Absent, the document's own hash is computed, which checks the gate rather than the
      operator's checksum discipline.
    * `--ref` — the ref to read the file list at (default `HEAD`).
    * `--out` — where the REDACTED artifact goes (default
      `docs/measurements/trigger_drift.json`). Safe to commit: see below.
    * `--full-out` — where the UNREDACTED artifact goes (default
      `tmp/gate_measurement/trigger_drift.full.json`, gitignored). It names every pattern, its
      match count, the local checkout path and the target tree's size.

  ## What the redacted artifact may carry

  Per pattern: its kind, its configuration index, and whether it matched anything. A BOOLEAN,
  not the match count — the assertion needs only "at least one", and a count would publish how
  broadly each guard reaches for no gain. The count is in the unredacted artifact, which is
  where a reader comparing two runs for an over-broad pattern is already looking.

  **`meta` is redacted on the same rule, and it was not at first.** A local absolute checkout
  path is nobody's business in a public repository — PR #830's own first review removed exactly
  that key from its artifacts — and `tree_files` is the private repository's file count, which
  no reading of "a boolean, not a count" permits. Both are dropped from the redacted report and
  kept in the full one. What remains identifies the run without describing the target: the
  `owner/repo` key (already public in the design), the ref and head, the trigger fingerprint,
  the timestamp and the harness name.

  ## Fail closed

  Every one of these exits non-zero rather than reporting a clean tree: a checkout that cannot
  be read, an empty file list, a document that does not parse, a document that does not name
  `--repo-name`, and any unmatched pattern. A checker that cannot read the tree has proved
  nothing, and "no patterns drifted" over no files is the vacuous pass this task exists to
  prevent.
  """

  use Mix.Task

  alias Loopctl.DeliveryGates.TriggerDrift
  alias Loopctl.DeliveryGates.Triggers

  @switches [
    repo: :string,
    repo_name: :string,
    triggers: :string,
    sha256: :string,
    ref: :string,
    out: :string,
    full_out: :string
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    repo = required(opts, :repo)
    repo_name = required(opts, :repo_name)
    ref = opts[:ref] || "HEAD"

    document = read_triggers!(required(opts, :triggers))
    sha256 = checksum!(document, opts[:sha256])
    repo_triggers = repo_triggers!(Triggers.parse(document, sha256), repo_name)
    {files, head} = read_tree!(repo, ref)

    coverage =
      case TriggerDrift.coverage(repo_triggers, files) do
        {:ok, coverage} -> coverage
        {:error, reason} -> Mix.raise("cannot check drift: #{inspect(reason)}")
      end

    meta = %{
      repo: repo_name,
      checkout: repo,
      ref: ref,
      head: head,
      tree_files: length(files),
      trigger_fingerprint: String.slice(sha256, 0, 12),
      trigger_checksum_source: if(opts[:sha256], do: "operator_pin", else: "computed"),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      harness: "mix loopctl.gates.check_drift"
    }

    write(
      report(coverage, meta, :redacted),
      out(opts, :out, "docs/measurements/trigger_drift.json")
    )

    write(
      report(coverage, meta, :full),
      out(opts, :full_out, "tmp/gate_measurement/trigger_drift.full.json")
    )

    report_drift(coverage)
  end

  # Every `meta` key the REDACTED report drops. Named here rather than allow-listed so a new
  # key is published by default and a reviewer sees it in the diff — the reverse (an allow-list)
  # silently drops a key somebody added for a reason.
  @unpublishable_meta_keys [
    # a local absolute path on whichever machine ran the check
    :checkout,
    # the private repository's file count
    :tree_files
  ]

  @doc """
  The artifact, as a map. Public so the test asserting over a committed artifact and the task
  writing one agree on its shape — including the `meta` redaction, which is where the first
  leak was.
  """
  @spec report([TriggerDrift.pattern_coverage()], map(), :redacted | :full) :: map()
  def report(coverage, meta, detail) do
    %{
      check: "gate_b_trigger_drift",
      question:
        "Does every configured Gate B pattern still match a file in the target repository?",
      meta: meta(meta, detail),
      totals: %{
        patterns: length(coverage),
        effect_patterns: Enum.count(coverage, &(&1.kind == :effect)),
        human_patterns: Enum.count(coverage, &(&1.kind == :human)),
        unmatched: Enum.count(coverage, &(&1.matches == 0))
      },
      patterns: Enum.map(coverage, &row(&1, detail))
    }
  end

  defp meta(meta, :redacted), do: Map.drop(meta, @unpublishable_meta_keys)
  defp meta(meta, :full), do: meta

  # Redacted: kind, configuration index, and whether the pattern matched anything. The pattern
  # text is the guard map itself, and the match count is how broadly each guard reaches; neither
  # reaches a committed artifact.
  defp row(entry, :redacted) do
    %{kind: entry.kind, index: entry.index, matched: entry.matches > 0}
  end

  defp row(entry, :full), do: entry

  defp report_drift(coverage) do
    case Enum.filter(coverage, &(&1.matches == 0)) do
      [] ->
        Mix.shell().info("no drift: #{length(coverage)} configured patterns, every one matching")

      drifted ->
        Mix.raise("""
        #{length(drifted)} configured pattern(s) match NOTHING in the target repository.

        Each one has stopped guarding the path it names — most often because the path was
        renamed. The patterns are named in the unredacted artifact, never on stdout.

        #{Enum.map_join(drifted, "\n", &"  #{&1.kind} pattern ##{&1.index}")}
        """)
    end
  end

  defp repo_triggers!({:ok, %Triggers{} = triggers}, repo_name) do
    case Triggers.fetch_repo(triggers, repo_name) do
      {:ok, repo_triggers} ->
        repo_triggers

      :error ->
        Mix.raise("the trigger document does not name #{repo_name}")
    end
  end

  defp repo_triggers!({:error, :checksum_mismatch}, _repo_name) do
    Mix.raise("""
    the document at --triggers does not hash to the checksum given as --sha256.

    The bytes are hashed EXACTLY as read, which is what production does. The usual cause is a
    trailing newline: a file written with one has a different checksum from the same JSON set
    as a secret. That is the trap deploy/FLY_SECRETS.md documents, and a run that papered over
    it would check a document production is not running.
    """)
  end

  defp repo_triggers!({:error, reason}, _repo_name) do
    Mix.raise("the trigger document did not parse: #{inspect(reason)}")
  end

  defp read_triggers!(path) do
    case File.read(path) do
      {:ok, document} ->
        document

      {:error, reason} ->
        Mix.raise("cannot read the trigger document at #{path}: #{:file.format_error(reason)}")
    end
  end

  @doc """
  The checksum `Loopctl.DeliveryGates.Triggers.parse/2` is verified against.

  An operator's PIN wins over the document's own hash, and is returned even when it does not
  match — a mismatch has to reach `parse/2` and be REFUSED there, because a pin that is
  silently replaced by the hash of whatever is on disk verifies a document against itself and
  can never fail. Public so that refusal is testable.
  """
  @spec checksum(binary(), String.t() | nil) :: String.t()
  def checksum(document, nil) when is_binary(document) do
    :sha256 |> :crypto.hash(document) |> Base.encode16(case: :lower)
  end

  def checksum(document, pinned) when is_binary(document) and is_binary(pinned) do
    String.downcase(pinned)
  end

  defp checksum!(document, pinned) do
    if is_binary(pinned) and not Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, pinned) do
      Mix.raise("--sha256 must be 64 hex characters")
    end

    checksum(document, pinned)
  end

  defp read_tree!(repo, ref) do
    head = repo |> git!(["rev-parse", ref]) |> String.trim()

    files =
      repo
      |> git!(["ls-tree", "-r", "--name-only", "-z", ref])
      |> String.split(<<0>>, trim: true)

    if files == [], do: Mix.raise("#{repo} at #{ref} lists no files — refusing a vacuous pass")

    {files, head}
  end

  # `-z` so a path with a special byte arrives unquoted, the same form the gate is given and the
  # only form an anchored pattern can match (see `GateB`'s note on `core.quotePath`).
  #
  # stderr is NEVER merged into stdout. git writes advisories there on a perfectly successful
  # read, and merged they become DATA: a warning ahead of `rev-parse`'s output is recorded
  # verbatim as the head sha, and one ahead of `ls-tree -z` carries no NUL, so it is glued onto
  # the first path and that path silently stops matching any pattern. It goes to this process's
  # stderr instead, where an operator reads it and the parser never sees it.
  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: false) do
      {output, 0} ->
        output

      {_output, status} ->
        Mix.raise(
          "git #{Enum.join(args, " ")} in #{repo} exited #{status} — git's own diagnostic is on stderr"
        )
    end
  end

  defp out(opts, key, default), do: opts[key] || default

  defp write(report, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
    Mix.shell().info("wrote #{path}")
  end

  defp required(opts, key) do
    opts[key] || Mix.raise("--#{String.replace(to_string(key), "_", "-")} is required")
  end
end
