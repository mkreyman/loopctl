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
    * `--corpus` — a label for the corpus, recorded on the artifact (default the tickets path).
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
    out: :string,
    full_out: :string,
    summary: :string
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    path = opts[:tickets] || Mix.raise("--tickets is required")
    {tickets, rejected} = read_tickets(path)

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
      corpus: opts[:corpus] || path,
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
  defp read_tickets(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, tickets, rejected} <- Ticket.parse_all(decoded) do
      {tickets, rejected}
    else
      {:error, %Jason.DecodeError{} = error} ->
        Mix.raise("#{path} is not valid JSON: #{Exception.message(error)}")

      {:error, :not_a_list} ->
        Mix.raise("#{path} must be a JSON ARRAY, as `gh issue list --json` emits")

      {:error, reason} ->
        Mix.raise("cannot read #{path}: #{inspect(reason)}")
    end
  end

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
