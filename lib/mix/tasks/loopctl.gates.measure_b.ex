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
    * `--since` / `--until` — the window, in anything `git log` accepts. Absent, the whole
      first-parent history up to the checkout's HEAD.
    * `--limit` — cap the number of changes (newest first). For a quick run.
    * `--out` — where the REDACTED machine-readable artifact goes (default
      `docs/measurements/gate_b_<date>.json`). Safe to commit: no file paths, no trigger
      patterns, no pull request titles.
    * `--full-out` — where the UNREDACTED artifact goes (default
      `tmp/gate_measurement/gate_b_<date>.full.json`, which is gitignored). It carries paths and
      subjects and must not be committed to a public repository.
    * `--summary` — where the human summary goes. Printed either way.

  ## Reproducing a run

  Two things move under a replay: the checkout's HEAD and the trigger document. The artifact
  records the head sha, the window as given, the number of changes, and the trigger
  fingerprint, so a later run can say whether it measured the same corpus against the same
  configuration. It does NOT fetch, so the window's upper end is whatever the local checkout
  holds.
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
      trigger_status: trigger_status(triggers),
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

  defp replay(repo, repo_name, triggers, opts) do
    stream_opts = Keyword.take(opts, [:since, :until, :limit])

    head =
      case RepoHistory.git(repo, ["rev-parse", "HEAD"]) do
        {:ok, sha} -> String.trim(sha)
        {:error, reason} -> Mix.raise("cannot read HEAD of #{repo}: #{inspect(reason)}")
      end

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
        Mix.raise("cannot read #{repo}: #{inspect(reason)}")
    end
  end

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

  defp announce_triggers({:error, reason}, sha256) do
    Mix.shell().error(
      "triggers: DID NOT PARSE (#{inspect(reason)}), fingerprint #{String.slice(sha256, 0, 12)}. " <>
        "Every change will escalate as :human — that is the gate failing closed, not a measurement of it."
    )
  end

  defp trigger_status({:ok, _triggers}), do: "parsed"
  defp trigger_status({:error, reason}), do: "error: #{inspect(reason)}"

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
