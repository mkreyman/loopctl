defmodule Mix.Tasks.LoopctlRunner.Eval do
  @shortdoc "Runs an agent spec's eval cases offline through the runner's own path"

  @moduledoc """
  US-48.10: a spec's eval set, run through the runner's own launcher and session path, with no
  control socket and against fixture repositories only.

      mix loopctl_runner.eval SPEC[@VERSION] [--eval-dir DIR] [--results-dir DIR]
                              [--scratch-dir DIR] [--keep-scratch]
                              [--launcher PATH] [--cli DIR]
                              [--grant-dir DIR] [--projects-dir DIR]

  Runs every case in `eval/SPEC@VERSION/` (every version of SPEC when none is named), writes one
  result per case to `eval/results/SPEC@VERSION/<case>.json`, prints a per-case pass/fail table
  and exits non-zero naming every failing case. A run that refuses to start — a case that does
  not load, a fixture outside `eval/fixtures`, a launcher the runner would not use — exits
  non-zero having run nothing.

  `--scratch-dir DIR` is where the fixtures are cloned and the sessions run. A DIR that already
  exists is never deleted or emptied: the run works in a new, uniquely named subdirectory of it
  and removes only that afterwards (`--keep-scratch` keeps it, and prints `scratch kept at
  <path>` naming the directory actually used). A DIR that does not exist is created and removed
  whole, with any missing parent the run created. Fixtures resolve inside DIR as named.

  `--launcher` is the `claude-headless.sh` every session goes through (default claude-config's).
  `--cli DIR` puts DIR first on each session's `PATH`, so the launcher finds that directory's
  `claude`: the suite's fake CLI (`test/support/bin`), which also reads each case's offline
  response from `eval/offline/`. Without it the cases run on the real model, through the same
  launcher as every unattended session, with `ANTHROPIC_API_KEY` unset by it.

  See `LoopctlRunner.Eval`.
  """

  use Mix.Task

  alias LoopctlRunner.Eval

  @switches [
    eval_dir: :string,
    results_dir: :string,
    scratch_dir: :string,
    keep_scratch: :boolean,
    launcher: :string,
    cli: :string,
    grant_dir: :string,
    projects_dir: :string
  ]

  @usage "usage: mix loopctl_runner.eval SPEC[@VERSION] [--cli DIR] [--launcher PATH] " <>
           "[--eval-dir DIR] [--results-dir DIR] [--scratch-dir DIR] [--keep-scratch] " <>
           "[--grant-dir DIR] [--projects-dir DIR]"

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [spec_arg], []} ->
        Mix.Task.run("app.start")
        evaluate(spec_arg, opts)

      _ ->
        Mix.raise(@usage)
    end
  end

  defp evaluate(spec_arg, opts) do
    case Eval.run(spec_arg, eval_opts(opts)) do
      {:ok, results} ->
        Mix.shell().info(Eval.table(results))
        report(results)

      {:error, reason} ->
        Mix.raise("eval refused to run, nothing ran: " <> reason)
    end
  end

  defp report(results) do
    case Eval.failures(results) do
      [] ->
        Mix.shell().info("#{length(results)} of #{length(results)} cases passed")

      failed ->
        Mix.raise(
          "#{length(failed)} of #{length(results)} eval cases failed: " <> Enum.join(failed, ", ")
        )
    end
  end

  # A kept scratch directory is printed: inside an existing `--scratch-dir` the run used a fresh
  # subdirectory, and its name is known only once the run has made it.
  defp eval_opts(opts) do
    Enum.flat_map(opts, fn
      {:cli, dir} -> [cli_dir: dir]
      {key, value} -> [{key, value}]
    end) ++ [on_scratch_dir: &Mix.shell().info("scratch kept at " <> &1)]
  end
end
