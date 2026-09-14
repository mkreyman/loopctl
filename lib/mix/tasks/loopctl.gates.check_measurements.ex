defmodule Mix.Tasks.Loopctl.Gates.CheckMeasurements do
  @shortdoc "Assert every committed measurement artifact carries its pins and agrees with its peers"

  @moduledoc """
  #828 round-3 finding 6 — the enforceable half of `docs/measurements/README.md`'s cross-run
  rule.

  Two runs may be compared only when their pinning fields are identical AND quoted beside the
  comparison. Nothing mechanical can read the prose, but the precondition is checkable: every
  artifact must CARRY its pins, and two artifacts of the same gate keyed by the same pin must
  agree on the rest. See `Loopctl.DeliveryGates.Measurement.ArtifactPins` for what that covers
  and what it deliberately does not.

  ## Usage

      mix loopctl.gates.check_measurements
      mix loopctl.gates.check_measurements --dir docs/measurements

  Exits non-zero on any finding. `test/loopctl/delivery_gates/measurement/artifact_pins_test.exs`
  runs the same check over the committed directory, so CI enforces it without this task having
  to be wired into `mix precommit`.
  """

  use Mix.Task

  alias Loopctl.DeliveryGates.Measurement.ArtifactPins

  @default_dir "docs/measurements"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    {opts, _rest} = OptionParser.parse!(argv, strict: [dir: :string])
    dir = opts[:dir] || @default_dir

    case ArtifactPins.check(dir) do
      {:ok, count} ->
        Mix.shell().info(
          "#{count} measurement artifact(s) in #{dir}: pins present and consistent"
        )

      {:error, findings} ->
        Enum.each(findings, fn {where, why} -> Mix.shell().error("#{where} #{why}") end)
        Mix.raise("#{length(findings)} measurement artifact finding(s) in #{dir}")
    end
  end
end
