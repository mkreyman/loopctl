defmodule Mix.Tasks.Loopctl.Gates.MeasureA do
  @shortdoc "Replay Gate A over past tickets, log-only, and report its escalation rate"

  @moduledoc """
  #828, design §12 build order step 3 — run Gate A over past tickets WITHOUT gating, and record
  its escalation rate.

  Design §5: collapsing Gate A and Gate B into one escalation produced a measured 54% escalation
  rate on 80 first-parent commits, and "a rate resembling that is a design failure, not a tuning
  question". This is the run that says where Gate A actually sits.

  It changes no gate, writes nothing to the database, and gates nothing.

  ## What a replay can and cannot see

  Gate A's only input is the triage trio's three outputs, and history has no trio. The harness
  reconstructs one per ticket from signals that already exist on the ticket — read
  `Loopctl.DeliveryGates.Measurement.GateAReplay`'s moduledoc for the mapping — and hands it to
  the shipped `Loopctl.DeliveryGates.GateA.evaluate/1`.

  **Two of Gate A's four triggers are unobservable in a replay**: trio DISAGREEMENT, which the
  design calls the better signal, and `contradicts`. Both are therefore absent from every
  reconstructed output, which makes the measured rate a strict LOWER BOUND. The artifact says
  so on every run, and so does the summary.

  ## Usage

      gh issue list -R owner/repo --state all --limit 1000 \\
        --json number,title,body,labels,state,stateReason,createdAt > tickets.json

      mix loopctl.gates.measure_a \\
        --tickets tickets.json \\
        --corpus owner/repo \\
        --out docs/measurements/gate_a_2026-09-13.json \\
        --summary docs/measurements/gate_a_2026-09-13.md

  The `gh` call is the ONLY networked step and it is deliberately outside the task: the corpus
  is a file, so the run is offline, repeatable, and comparable against a later one.

  ## Options

    * `--tickets` (required) — path to the decoded `gh issue list --json` array.
    * `--corpus` (required) — a LABEL for the corpus, published on the artifact. Required rather
      than defaulted, because the obvious default is the tickets path and this value is
      published: an optional `--corpus` put an absolute local path into a committed artifact in
      a public repository.
    * `--expect-corpus` — the `corpus_fingerprint` a previous run recorded. Present, a corpus
      whose bytes differ REFUSES rather than measuring a different one. Every Gate A signal
      reads a mutable issue field — a title edited, a label applied, an issue closed as
      not-planned — so a corpus that moved is the same reproducibility hole `--head` closes on
      the Gate B side.
    * `--out` — the REDACTED machine-readable artifact (default
      `docs/measurements/gate_a_<date>.json`). Issue NUMBERS, dates and signals; no titles and
      no bodies, because `mkreyman/home_care_billing` is private and loopctl is public.
    * `--full-out` — the unredacted artifact, with titles (default
      `tmp/gate_measurement/gate_a_<date>.full.json`, which is gitignored).
    * `--summary` — where the human summary goes. Printed either way.
  """

  use Mix.Task

  alias Loopctl.DeliveryGates.Measurement.GateAReplay
  alias Loopctl.DeliveryGates.Measurement.Report
  alias Loopctl.DeliveryGates.Measurement.Ticket

  @switches [
    tickets: :string,
    corpus: :string,
    expect_corpus: :string,
    out: :string,
    full_out: :string,
    summary: :string
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    path = opts[:tickets] || Mix.raise("--tickets is required")

    # REQUIRED, and not defaulted to the tickets path. A default that falls back to a file path
    # publishes an absolute local path into a committed artifact in a public repository, which
    # is what happened when it was optional. `--repo-name` on the Gate B task is required for
    # the same shape of reason: nothing about the corpus is inferred.
    corpus =
      opts[:corpus] ||
        Mix.raise("--corpus is required: a LABEL for the corpus, not a path (it is published)")

    {tickets, rejected, fingerprint} = read_tickets(path, opts[:expect_corpus])

    if tickets == [] do
      Mix.raise("no tickets in #{path} — a rate over nothing is not a rate")
    end

    replays = Enum.map(tickets, &GateAReplay.replay/1)

    # The same corpus with the one judgement call suppressed — see `Report.gate_a/3`'s
    # `:sensitivity`. Two runs, because Gate A's rate turns almost entirely on whether a feature
    # request counts as a workflow change, and a single number would hide that.
    without_workflow =
      Enum.map(tickets, &GateAReplay.replay(&1, suppress: [:request_shaped?]))

    meta = %{
      corpus: corpus,
      # The Gate B run pins its corpus with `--head` and records the resolved sha. Gate A's
      # corpus is a FILE, and every signal it reads is a mutable issue field — a title edited, a
      # label applied, an issue closed as not-planned all move the rate — so without this the
      # same reproducibility hole `--head` closed is open on this side. Truncated for the same
      # reason the trigger fingerprint is.
      corpus_fingerprint: fingerprint,
      tickets_file: path,
      tickets: length(tickets),
      unparseable_records: length(rejected),
      unparseable_reasons: Enum.map(rejected, &inspect/1),
      since: oldest(tickets),
      until: newest(tickets),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      harness: "mix loopctl.gates.measure_a"
    }

    redacted = Report.gate_a(replays, meta, detail: :redacted, sensitivity: without_workflow)

    write(redacted, opts[:out] || default("docs/measurements", "gate_a", "json"))

    write(
      Report.gate_a(replays, meta, detail: :full, sensitivity: without_workflow),
      opts[:full_out] || full_default("gate_a")
    )

    summary = Report.summarize(redacted)
    Mix.shell().info("\n" <> summary)
    if summary_path = opts[:summary], do: write_text(summary_path, summary <> "\n")
  end

  # A record the parser refused is COUNTED, never dropped and never defaulted: a corpus quietly
  # missing what would not parse is a denominator nobody can check.
  #
  # The fingerprint is over the FILE's bytes, taken before anything is decoded, so it identifies
  # the corpus rather than the parse. `--expect-corpus` REFUSES a mismatch rather than warning:
  # a re-run meant to be compared against a recorded run has no use for a different corpus, and
  # the whole reason this exists is that a corpus moved under a run once already.
  defp read_tickets(path, expected) do
    with {:ok, body} <- File.read(path),
         fingerprint = fingerprint(body),
         :ok <- expect(fingerprint, expected),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, tickets, rejected} <- Ticket.parse_all(decoded) do
      {tickets, rejected, fingerprint}
    else
      {:error, %Jason.DecodeError{} = error} ->
        Mix.raise("#{path} is not valid JSON: #{Exception.message(error)}")

      {:error, :not_a_list} ->
        Mix.raise("#{path} must be a JSON ARRAY, as `gh issue list --json` emits")

      {:error, {:corpus_mismatch, actual, wanted}} ->
        Mix.raise(
          "the ticket corpus is not the one this run expected: #{actual} but --expect-corpus " <>
            "asked for #{wanted}. Re-fetch it, or drop --expect-corpus and measure a NEW corpus."
        )

      {:error, reason} ->
        Mix.raise("cannot read #{path}: #{inspect(reason)}")
    end
  end

  defp fingerprint(body) do
    :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower) |> String.slice(0, 12)
  end

  defp expect(_fingerprint, nil), do: :ok
  defp expect(fingerprint, fingerprint), do: :ok
  defp expect(actual, wanted), do: {:error, {:corpus_mismatch, actual, wanted}}

  defp oldest(tickets),
    do: tickets |> Enum.map(& &1.created_at) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)

  defp newest(tickets),
    do: tickets |> Enum.map(& &1.created_at) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

  defp default(dir, prefix, extension) do
    Path.join(dir, "#{prefix}_#{Date.utc_today() |> Date.to_iso8601()}.#{extension}")
  end

  defp full_default(prefix) do
    Path.join(
      "tmp/gate_measurement",
      "#{prefix}_#{Date.utc_today() |> Date.to_iso8601()}.full.json"
    )
  end

  defp write(report, path), do: write_text(path, Jason.encode!(report, pretty: true) <> "\n")

  defp write_text(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    Mix.shell().info("wrote #{path}")
  end
end
