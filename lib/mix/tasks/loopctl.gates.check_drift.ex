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

  **`meta` is redacted on the same rule, by an ALLOW-list, and neither was true at first.** It
  carried a local absolute checkout path — PR #830's own first review removed exactly that key
  from its artifacts — and `tree_files`, the private repository's file count, which no reading
  of "a boolean, not a count" permits. What remains identifies the run without describing the
  target: the `owner/repo` key (already public in the design), the head, the trigger
  fingerprint, whether that fingerprint was pinned or computed, the timestamp and the harness.

  The list is an allow-list rather than a deny-list because the two fail in opposite directions
  and only one of them is noticed — see the note above `@published_meta_keys`. A key nobody has
  thought of yet is full-detail only, by default, without anyone having to remember.

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

  # The `meta` keys a REDACTED artifact publishes. An ALLOW-list: everything not named here is
  # full-detail only, including a key nobody has thought of yet.
  #
  # This was a DENY-list for one round, on the argument that a new key then shows up in a diff
  # rather than vanishing silently. That argument loses to a measurement. A deny-list is updated
  # by whoever ADDS a key; an allow-list is updated by whoever wants one PUBLISHED, which is the
  # person who has thought about it — and the same leak escaped review twice under the first
  # rule, in PR #830's first round (two absolute paths) and in this task's first round
  # (`:checkout`, plus `:tree_files`, which nobody had discussed at all). "A reviewer sees it in
  # the diff" is a claim about reviewers, and the reviewers did not see it either time.
  #
  # The two failure modes are not symmetric, which is what decides it. An allow-list fails by
  # DROPPING a field somebody wanted, and a missing field on an artifact gets noticed. A
  # deny-list fails by PUBLISHING a path out of a private repository, and nothing notices.
  #
  # Why each of these is safe to publish:
  #
  # - `:repo` — the `owner/repo` key, already public in the design document.
  # - `:head` — the commit the tree was read at. It identifies the corpus and describes nothing.
  # - `:trigger_fingerprint` — 12 characters of the document's SHA-256, the same truncated
  #   commitment the measurement artifacts publish and for the same reason.
  # - `:trigger_checksum_source` — `"operator_pin"` or `"computed"`. A property of the RUN, not
  #   of the machine or the target: it is the only field that says whether the fingerprint was
  #   verified against the checksum production pinned or merely recomputed from a local file.
  # - `:generated_at`, `:harness` — when, and by what.
  #
  # Deliberately NOT here: `:checkout` and `:tree_files` (an absolute local path, and a private
  # repository's file count, which no reading of "a boolean, not a count" permits), and `:ref`
  # (the resolved head sha is strictly more precise about which tree was read).
  @published_meta_keys [
    :generated_at,
    :harness,
    :head,
    :repo,
    :trigger_checksum_source,
    :trigger_fingerprint
  ]

  @doc """
  The `meta` keys a REDACTED artifact publishes.

  Public so a test can bind this task's redaction to the measurement harness's — two
  implementations of one redaction rule is the underlying defect, and this list is the half of
  it that survives until `Loopctl.DeliveryGates.Measurement.Report` is on this branch and can be
  called directly.
  """
  @spec published_meta_keys() :: [atom()]
  def published_meta_keys, do: @published_meta_keys

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

  defp meta(meta, :full), do: meta
  defp meta(meta, _redacted), do: Map.take(meta, @published_meta_keys)

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

  # NEVER `inspect(reason)`: `{:invalid_pattern, ["repos", "<owner/repo>", "effect_paths"],
  # pattern}` carries a live guard pattern and the target repository's name, and this lands in a
  # terminal and in a runner log — as public as a committed artifact, by this task's own rule.
  # The scenario is exactly the one the task exists for: an operator hand-edits the document and
  # fat-fingers a glob.
  defp repo_triggers!({:error, reason}, _repo_name) do
    Mix.raise("""
    the trigger document did not parse: #{TriggerDrift.describe_error(reason)}

    The reason is reduced to its kind and the key path's depth on purpose — the full reason
    names the offending pattern. Read it from the document itself.
    """)
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
  The environment overrides that must be cleared before spawning git.

  Every one of these redirects repository discovery, and git EXPORTS them to hooks — so a `git`
  spawned from anything running under `mix precommit` inherits the repository being committed
  to, whatever `-C` says. Public so a test's own git calls clear exactly the same set: two lists
  would be one list and one bug.
  """
  @spec git_env() :: [{String.t(), nil}]
  def git_env do
    for name <- ~w(
          GIT_DIR
          GIT_WORK_TREE
          GIT_COMMON_DIR
          GIT_INDEX_FILE
          GIT_OBJECT_DIRECTORY
          GIT_ALTERNATE_OBJECT_DIRECTORIES
          GIT_NAMESPACE
          GIT_PREFIX
          GIT_CEILING_DIRECTORIES
        ),
        do: {name, nil}
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

  # The file list is read at the RESOLVED sha, never at `ref` again. These are two processes,
  # and the moduledoc blesses pointing this at a tree somebody is working in: a commit landing
  # between them would pair the pre-commit sha with the post-commit tree, and the artifact would
  # certify no drift at a head it did not read.
  #
  # `ref` is deliberately OUT OF SCOPE in `files_at/2`, rather than merely unused there. This
  # race cannot be provoked by a deterministic test — it needs a commit to land between two
  # processes — so the defect is made unrepresentable instead of guarded: re-introducing it
  # would not compile. A sha cannot move.
  defp read_tree!(repo, ref) do
    head = repo |> git!(["rev-parse", ref]) |> String.trim()
    files = files_at(repo, head)

    if files == [], do: Mix.raise("#{repo} at #{ref} lists no files — refusing a vacuous pass")

    {files, head}
  end

  defp files_at(repo, head) do
    repo
    |> git!(["ls-tree", "-r", "--name-only", "-z", head])
    |> String.split(<<0>>, trim: true)
  end

  # `-z` so a path with a special byte arrives unquoted, the same form the gate is given and the
  # only form an anchored pattern can match (see `GateB`'s note on `core.quotePath`).
  #
  # stderr is NEVER merged into stdout. git writes advisories there on a perfectly successful
  # read, and merged they become DATA: a warning ahead of `rev-parse`'s output is recorded
  # verbatim as the head sha, and one ahead of `ls-tree -z` carries no NUL, so it is glued onto
  # the first path and that path silently stops matching any pattern. It goes to this process's
  # stderr instead, where an operator reads it and the parser never sees it.
  #
  # And the environment is SCRUBBED. git hooks export `GIT_DIR`, and `mix precommit` runs the
  # suite from inside one, so anything git this process spawns inherits it — `-C` changes
  # directory while `GIT_DIR` overrides discovery, so `git -C /some/other/repo ls-tree` reads
  # the repository the hook is committing to and this task certifies drift against a tree it
  # never looked at. Measured, not theorised: a test fixture doing exactly this committed to
  # loopctl's own branch. `--repo` must mean `--repo`.
  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: false, env: git_env()) do
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
