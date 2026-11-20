defmodule LoopctlE2e.Run do
  @moduledoc """
  One happy-path run (AC-52.9.3..5): open an issue on the sandbox, walk `LoopctlE2e.Stages`
  in order, then check nothing is left open.

  Everything the loop depends on is an argument: the client, the clock and the sleep. A unit
  test passes a stub client and a fake clock that advances on each sleep, so the backoff and
  the budgets are tested in microseconds.

  Polling backs off from 10 s, doubling, to 120 s, and starts again at 10 s for each stage. A
  stage that is not reached within its own budget, or within what is left of the run's
  120 minutes, fails the run naming the stage, the story and the last state read.
  """

  alias LoopctlE2e.Client
  alias LoopctlE2e.Stages

  @first_poll_ms 10_000
  @max_poll_ms 120_000
  @total_budget_ms 120 * 60_000

  @type opts :: [
          stages: [Stages.stage()],
          now: (-> integer()),
          sleep: (non_neg_integer() -> any()),
          log: (String.t() -> any()),
          total_budget_ms: pos_integer()
        ]

  @type failure :: %{stage: atom(), story_id: String.t() | nil, last_state: String.t()}

  @doc """
  A run id: the UTC timestamp and 6 random hex characters, letters and digits only, so
  `Sandbox.Runs.R<run_id>` is a valid module name.
  """
  @spec run_id(DateTime.t()) :: String.t()
  def run_id(now \\ DateTime.utc_now()) do
    Calendar.strftime(now, "%Y%m%d%H%M%S") <>
      Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
  end

  @doc "The issue a run opens (AC-52.9.3)."
  @spec issue(String.t(), String.t()) :: map()
  def issue(run_id, label) do
    %{
      title: "e2e #{run_id}: add Sandbox.Runs.R#{run_id}.value/0 returning #{run_id}",
      body:
        "Add `lib/sandbox/runs/r#{run_id}.ex` defining `Sandbox.Runs.R#{run_id}` with " <>
          "`value/0` returning the string `\"#{run_id}\"`, and a test asserting it.\n\n" <>
          "Opened by loopctl's nightly e2e run (US-52.9).",
      labels: [label]
    }
  end

  @doc """
  Opens the run's issue and walks every stage. `sandbox` carries `:repo`, `:project_id` and
  `:label`. Returns the final context, or the failure naming the stage.
  """
  @spec execute(Client.t(), map(), String.t(), opts()) :: {:ok, map()} | {:error, failure()}
  def execute(client, sandbox, run_id, opts \\ []) do
    log = Keyword.get(opts, :log, fn _ -> :ok end)

    case Client.post(
           client,
           :github,
           "/repos/#{sandbox.repo}/issues",
           issue(run_id, sandbox.label)
         ) do
      {:ok, 201, %{"number" => number}} ->
        log.("opened #{sandbox.repo}##{number} for run #{run_id}")

        ctx = %{
          repo: sandbox.repo,
          project_id: sandbox.project_id,
          run_id: run_id,
          issue_number: number,
          story: nil
        }

        with {:ok, ctx} <- walk(client, ctx, opts), do: clean(client, ctx)

      other ->
        {:error, %{stage: :issue_opened, story_id: nil, last_state: inspect(other, limit: 5)}}
    end
  end

  @doc "Walks `opts[:stages]` (default `Stages.all/0`) from `ctx`."
  @spec walk(Client.t(), map(), opts()) :: {:ok, map()} | {:error, failure()}
  def walk(client, ctx, opts \\ []) do
    now = Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end)
    deadline = now.() + Keyword.get(opts, :total_budget_ms, @total_budget_ms)

    opts
    |> Keyword.get(:stages, Stages.all())
    |> Enum.reduce_while({:ok, ctx}, fn stage, {:ok, ctx} ->
      stage_deadline = min(now.() + stage.budget_ms, deadline)

      case poll(client, ctx, stage, stage_deadline, @first_poll_ms, nil, opts) do
        {:ok, ctx} -> {:cont, {:ok, ctx}}
        {:error, _} = failure -> {:halt, failure}
      end
    end)
  end

  defp poll(client, ctx, stage, deadline, interval, last, opts) do
    now = Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    log = Keyword.get(opts, :log, fn _ -> :ok end)

    case stage.check.(client, ctx) do
      {:done, ctx} ->
        log.("#{stage.name}: reached")
        {:ok, ctx}

      {:fail, state} ->
        {:error, failure(stage, ctx, state)}

      {:wait, state} ->
        if state != last, do: log.("#{stage.name}: #{state}")
        left = deadline - now.()

        if left <= 0 do
          {:error, failure(stage, ctx, state)}
        else
          sleep.(min(interval, left))
          poll(client, ctx, stage, deadline, min(interval * 2, @max_poll_ms), state, opts)
        end
    end
  end

  defp clean(client, ctx) do
    case Stages.leftovers(client, ctx) do
      [] -> {:ok, ctx}
      left -> {:error, failure(%{name: :clean}, ctx, Enum.join(left, "; "))}
    end
  end

  defp failure(stage, ctx, state) do
    story_id = if is_map(ctx.story), do: ctx.story["id"]
    %{stage: stage.name, story_id: story_id, last_state: state}
  end

  @doc "The failure as one line, the way the workflow log and the test report it."
  @spec describe(failure()) :: String.t()
  def describe(%{stage: stage, story_id: story_id, last_state: state}),
    do: "e2e run failed at #{stage} (story #{story_id || "none"}): #{state}"
end
