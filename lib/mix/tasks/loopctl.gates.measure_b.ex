defmodule Mix.Tasks.Loopctl.Gates.MeasureB do
  @shortdoc "Replay Gate B over a repository's merged history and count its false negatives"

  @moduledoc """
  #828, design §12 build order step 2 — measure Gate B's FALSE NEGATIVES offline, over real
  merged history, before it gates anything.

  A false negative is the one that matters: a change Gate B would have CLEARED for auto-merge
  that a human would not have. The gate's own code decides "cleared"
  (`Loopctl.Delivery.MergePrecondition.gate_b_verdict/2` over an input built by
  `Loopctl.DeliveryGates.DiffNames`, plus the design's hard bound); an independent, path-blind
  oracle over the diff's own text decides "a human would not have"
  (`Loopctl.DeliveryGates.Measurement.EffectOracle`).

  It changes no gate, writes nothing to the database, and gates nothing. It reads a git
  checkout READ-ONLY — `log`, `diff` and `ls-tree` only — so it is safe to point at a checkout
  somebody is working in.

  ## Usage

      mix loopctl.gates.measure_b \\
        --repo /path/to/checkout \\
        --repo-name owner/repo \\
        --triggers /path/to/triggers.json \\
        --out docs/measurements/gate_b_2026-09-13.json \\
        --summary docs/measurements/gate_b_2026-09-13.md

  ## Options

    * `--repo` (required) — path to the target repository's checkout.
    * `--repo-name` (required) — the `owner/repo` key the trigger document uses. It is NOT
      inferred from the remote: the trigger document is keyed by it, and inferring it would let
      a differently-named remote be judged against another repository's trigger list.
    * `--triggers` (required) — path to the Gate B trigger JSON document. NOT committed and
      never printed: it is a map of which paths skip human review, which is why design §13 keeps
      it in configuration rather than in this public repository. The artifact records only the
      first 12 characters of its SHA-256, as a fingerprint that identifies a run without being a
      verification oracle for a guessed document.
    * `--sha256` — pin the checksum instead of computing it from the file's bytes. Absent, the
      harness computes it, which measures the GATE rather than the operator's checksum
      discipline. Pass it to reproduce a run against the exact bytes production had.
    * `--head` — the commit the window runs back from (default `HEAD`, resolved to a sha before
      anything is read). **Pass a previous run's recorded head to reproduce it.** A checkout is
      not a fixed corpus: the target's HEAD advanced under this harness between two runs on
      2026-09-13 and the corpus silently grew by 23 changes, which is how a set of numbers came
      to be reported against an artifact that no longer produced them.
    * `--since` / `--until` — the window, in anything `git log` accepts. Absent, the whole
      first-parent history up to `--head`.
    * `--limit` — cap the number of changes (newest first). For a quick run.
    * `--out` — where the REDACTED machine-readable artifact goes (default
      `docs/measurements/gate_b_<date>.json`). Safe to commit: no file paths, no trigger
      patterns, no pull request titles.
    * `--full-out` — where the UNREDACTED artifact goes (default
      `tmp/gate_measurement/gate_b_<date>.full.json`, which is gitignored). It carries paths and
      subjects and must not be committed to a public repository.
    * `--summary` — where the human summary goes. Printed either way.

  ## Reproducing a run

  Two things move under a replay: the checkout's tip and the trigger document. The artifact
  records the RESOLVED head sha, the window as given, the number of changes, and the trigger
  fingerprint, so a later run can say whether it measured the same corpus against the same
  configuration — and `--head <that sha>` makes it measure the same one. It does NOT fetch,
  so an unpinned run's upper end is whatever the local checkout holds at that moment.

  **A run's numbers and its artifact are ONE record.** Nothing in a report is safe to quote from
  an earlier run of the same command: re-run and restate, or pin `--head` and prove they match.
  """

  use Mix.Task

  alias Loopctl.DeliveryGates.Measurement.GateBReplay
  alias Loopctl.DeliveryGates.Measurement.RepoHistory
  alias Loopctl.DeliveryGates.Measurement.Report
  alias Loopctl.DeliveryGates.Triggers

  @switches [
    repo: :string,
    repo_name: :string,
    triggers: :string,
    sha256: :string,
    head: :string,
    since: :string,
    until: :string,
    limit: :integer,
    out: :string,
    full_out: :string,
    summary: :string
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    repo = required(opts, :repo)
    repo_name = required(opts, :repo_name)
    triggers_path = required(opts, :triggers)

    {document, sha256} = read_triggers(triggers_path, opts[:sha256])
    triggers = Triggers.parse(document, sha256)
    announce_triggers(triggers, sha256)

    {results, head} = replay(repo, repo_name, triggers, opts)

    meta = %{
      repo: repo_name,
      checkout: repo,
      head: head,
      since: opts[:since],
      until: opts[:until],
      limit: opts[:limit],
      # A TRUNCATED commitment to the document's bytes, so two runs can say whether they
      # measured the same configuration. Truncated because the full checksum would let a guessed
      # document be confirmed against a public artifact; 12 characters is a compromise, not a
      # guarantee, and the residual is stated in docs/measurements/README.md.
      trigger_fingerprint: String.slice(sha256, 0, 12),
      trigger_status: Report.trigger_status(triggers),
      trigger_shape: trigger_shape(triggers),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      harness: "mix loopctl.gates.measure_b"
    }

    write(Report.gate_b(results, meta, detail: :redacted), out(opts, "gate_b"))
    write(Report.gate_b(results, meta, detail: :full), full_out(opts, "gate_b"))

    summary = Report.summarize(Report.gate_b(results, meta, detail: :redacted))
    Mix.shell().info("\n" <> summary)
    if path = opts[:summary], do: write_text(path, summary <> "\n")
  end

  # The tip is RESOLVED to a sha before anything is read, and the resolved sha — not the ref the
  # operator typed — is what the window runs back from and what the artifact records. Resolving
  # once is the difference between a repeatable corpus and whatever the checkout happened to hold:
  # the target's HEAD advanced under this harness between two runs on 2026-09-13 and the corpus
  # silently grew by 23 changes.
  defp replay(repo, repo_name, triggers, opts) do
    requested = opts[:head] || "HEAD"

    head =
      case RepoHistory.git(repo, ["rev-parse", "--verify", requested <> "^{commit}"]) do
        {:ok, sha} ->
          String.trim(sha)

        {:error, reason} ->
          Mix.raise("cannot resolve #{requested} in #{repo}: #{git_error_kind(reason)}")
      end

    stream_opts = opts |> Keyword.take([:since, :until, :limit]) |> Keyword.put(:head, head)

    case RepoHistory.stream(repo, stream_opts) do
      {:ok, stream} ->
        results =
          stream
          |> Stream.map(fn
            {:ok, change} -> GateBReplay.replay(change, repo_name, triggers)
            {:error, {sha, reason}} -> GateBReplay.unreadable(sha, reason)
          end)
          |> Enum.to_list()

        if results == [] do
          Mix.raise("no changes in the window — a rate over nothing is not a rate")
        end

        {results, head}

      {:error, reason} ->
        Mix.raise("cannot read #{repo}: #{git_error_kind(reason)}")
    end
  end

  # The KIND, never the payload — the same reduction `announce_triggers/2` applies. A git failure
  # carries the command's output, and git names object ids, submodule paths and ref names of the
  # PRIVATE repository in it; `Mix.raise` puts that on the console, which this task's own
  # redaction note calls as readily pasted into a pull request as an artifact is committed.
  defp git_error_kind({:git_failed, status, _output}), do: "git exited #{status}"
  defp git_error_kind({:git_unavailable, _message}), do: "git could not be run"
  defp git_error_kind(reason) when is_atom(reason), do: to_string(reason)

  defp git_error_kind(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: reason |> elem(0) |> to_string()

  defp git_error_kind(_reason), do: "unrecognised failure"

  # The document's bytes are hashed EXACTLY as read, with no trailing-newline handling, because
  # that is what `Loopctl.DeliveryGates.Triggers.parse/2` hashes. A file written with a trailing
  # newline therefore has a different checksum from the same JSON set as a secret — which is the
  # documented trap in deploy/FLY_SECRETS.md, and the harness must not paper over it.
  defp read_triggers(path, pinned) do
    case File.read(path) do
      {:ok, document} ->
        {document, pinned || :sha256 |> :crypto.hash(document) |> Base.encode16(case: :lower)}

      {:error, reason} ->
        Mix.raise("cannot read the trigger document at #{path}: #{:file.format_error(reason)}")
    end
  end

  # Never prints the document. A configuration failure is REPLAYED rather than refused — a run
  # over a broken document measures the fail-closed behaviour, which is a real thing to know —
  # but it says so loudly, because every outcome will be :human and the rates will be trivial.
  defp announce_triggers({:ok, _triggers}, sha256) do
    Mix.shell().info("triggers: parsed, fingerprint #{String.slice(sha256, 0, 12)}")
  end

  # The KIND, never the reason. `Triggers.parse/2` returns `{:invalid_pattern, ["repos",
  # "<owner/repo>", "effect_paths"], pattern}` — a live guard pattern and the private repository
  # together — and console output is pasted into pull requests and chat as readily as an artifact
  # is committed.
  defp announce_triggers({:error, reason}, sha256) do
    status = Report.trigger_status({:error, reason})

    Mix.shell().error(
      "triggers: DID NOT PARSE (#{status.kind}), fingerprint #{String.slice(sha256, 0, 12)}. " <>
        "Every change will escalate as :human — that is the gate failing closed, not a measurement of it. " <>
        "The full reason is in the unredacted artifact only."
    )
  end

  # COUNTS, never patterns. Enough for a reader to see that a later run's configuration grew or
  # shrank; not enough to reconstruct which paths skip human review.
  defp trigger_shape({:ok, %Triggers{version: version, repos: repos}}) do
    %{
      version: version,
      repos: map_size(repos),
      effect_patterns: Enum.sum(for {_name, r} <- repos, do: length(r.effect_paths)),
      human_patterns: Enum.sum(for {_name, r} <- repos, do: length(r.human_paths))
    }
  end

  defp trigger_shape(_triggers), do: nil

  defp out(opts, prefix) do
    opts[:out] || Path.join("docs/measurements", "#{prefix}_#{today()}.json")
  end

  defp full_out(opts, prefix) do
    opts[:full_out] || Path.join("tmp/gate_measurement", "#{prefix}_#{today()}.full.json")
  end

  defp today, do: Date.utc_today() |> Date.to_iso8601()

  defp write(report, path) do
    write_text(path, Jason.encode!(report, pretty: true) <> "\n")
  end

  defp write_text(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    Mix.shell().info("wrote #{path}")
  end

  defp required(opts, key) do
    opts[key] || Mix.raise("--#{String.replace(to_string(key), "_", "-")} is required")
  end
end
