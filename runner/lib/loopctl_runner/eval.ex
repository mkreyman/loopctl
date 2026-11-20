defmodule LoopctlRunner.Eval do
  @moduledoc """
  The eval harness (US-48.10): a small case set per agent spec, run OFFLINE through the runner's
  own path, so a prompt or spec change is measured before it ships rather than discovered on a
  live ticket. `mix loopctl_runner.eval <spec>[@<version>]` is its command line.

  ## What one case runs

    1. The case is loaded and checked (`LoopctlRunner.Eval.Case`), its fixture resolved inside
       `eval/fixtures` or the scratch directory (`LoopctlRunner.Eval.Fixture.resolve/3`) — every
       case of the run is checked before ANY runs, so a case that could reach outside the
       fixtures refuses the whole run (AC-48.10.5).
    2. The fixture is built (once per run) and cloned into the case's own scratch directory: a bare
       `origin.git` with the dispatch's base at the pinned commit, and a checkout of it.
    3. The dispatch (`input`, exactly as loopctl would send it) goes through the runner's own
       accept decision, `LoopctlRunner.DispatchPolicy.decide/3`, against a config whose only repo
       is that checkout, then through the accept path its template names — exactly what
       `LoopctlRunner.Control.work/3` does: `LoopctlRunner.Run.execute/3` for `run: :story`
       (implement@1), `LoopctlRunner.TriageRun.execute/4` for `run: :triage` (triage@1,
       reply_draft@1 and verify@1, whose tree is cut at the head its dispatch names, a commit of
       the fixture above the case's base). Those cut the worktree (a branch of its own for
       `:build`, a detached tree for the others), launch the session through the configured
       `claude-headless.sh`, and record the outcome in the run directory.
    4. The result is read OFF DISK as the live path reads it: a `:judge`'s or `:draft`'s message
       from the run directory (`LoopctlRunner.PendingVerdicts.read/1`, the bytes a restarted
       Control would push), a `:build`'s `session_ended` built from the run's own end summary by
       `LoopctlRunner.DispatchRun.session_ended/2`. Nothing is rebuilt in the harness's words.
    5. The expectations are judged (`LoopctlRunner.Eval.Judge`) and the result file written
       (`LoopctlRunner.Eval.Result`).

  ## What it never does

  It starts no `LoopctlRunner.Control`, so no socket is opened and nothing connects to loopctl:
  the control config handed to the policy carries no URL and no token, and the config the run gets
  has no control at all. Every session runs under `Session.mcp_isolation/1` with a config naming
  no MCP server, so a session cannot reach loopctl through the operator's MCP entry either: this
  is the one place the runner overrides the MCP set, and only an eval session gets it. Every
  repository a session touches is a clone of a fixture inside the
  scratch directory, and every dispatch is synthetic (PRD default 1).

  ## Injected inputs

  Everything that differs between a real eval and a test is an option, never a global:
  `:launcher` (the `claude-headless.sh` every session goes through, default claude-config's),
  `:cli_dir` (a directory put FIRST on the session's `PATH`, so the launcher finds its `claude`
  there — the suite's fake CLI — and with it each case's offline response), `:grant_dir`,
  `:projects_dir`, `:scratch_dir`, `:eval_dir`, `:results_dir`, `:machine`, `:path` (the `PATH`
  the cli dir is put in front of) and `:now`. A `:scratch_dir` that already exists is never
  removed: the run works in a fresh, uniquely named subdirectory of it and removes only that
  (unless `:keep_scratch`); one that does not exist is created and removed whole, with every
  missing parent the run created. `:on_scratch_dir` is called with the directory the run used
  when `:keep_scratch` keeps it. `run_cases/2` also takes `:prompt_transform`, a
  function from each case's rendered prompt to `{:ok, prompt}` or `{:error, reason}`: a
  `spec_tuner@1` critic scores a PROPOSED template by applying its diff to a copy of each prompt
  in memory, and a transform that refuses turns that case into a refusal, never a pass. Both take
  `:deadline_at`, the instant every session must be gone by: a case whose whole session no longer
  fits before it (less the kill grace and the clock-skew margin) is not started, and the run stops
  there with `{:error, reason}`, logged. `:runs_dir` is where every case's run is recorded (by
  default its own directory under the scratch directory, removed with it): a critic gives the
  tuning run's `RunState.nested_runs_dir/1`, outside the scratch directory, so that a runner that
  dies mid-critic leaves those runs where the reaper looks for orphans.
  """

  require Logger

  alias LoopctlRunner.{
    Config,
    ControlConfig,
    DispatchPolicy,
    DispatchRun,
    PendingVerdicts,
    Run,
    RunState,
    Session,
    Story,
    TriageRun
  }

  alias LoopctlRunner.Eval.{Case, Fixture, Judge, Result}

  @default_launcher "~/workspace/claude-config/bin/claude-headless.sh"

  @type case_result :: %{
          name: String.t(),
          set: String.t(),
          passed: boolean(),
          checks: [Judge.check()],
          outcome: String.t(),
          rubric: String.t() | nil,
          result_path: String.t()
        }

  @doc "The launcher a real eval goes through: claude-config's headless wrapper."
  @spec default_launcher() :: String.t()
  def default_launcher, do: Path.expand(@default_launcher)

  @doc """
  Runs every case of `spec_arg` (`triage` or `triage@1`) and writes one result file per case.
  `{:error, reason}` is a run that REFUSED to start: a case that does not load, a fixture outside
  the fixtures, a launcher the runner would not use. Nothing ran.
  """
  @spec run(String.t(), keyword()) :: {:ok, [case_result()]} | {:error, String.t()}
  def run(spec_arg, opts \\ []) do
    scratch(opts, fn ctx ->
      # Fixtures resolve against the scratch directory the OPERATOR named, not the subdirectory
      # this run works in: a manifest they put in `--scratch-dir` is inside the one they named.
      with {:ok, cases} <- Case.load_all(spec_arg, ctx.eval_dir, ctx.scratch_root),
           do: run_loaded(cases, ctx)
    end)
  end

  @doc """
  Runs cases already loaded (`LoopctlRunner.Eval.Case.load_all/3` or `Case.from_map/5`), exactly
  as `run/2` runs a set it loads itself. The spec tuner's critic runs the existing set plus the
  cases a tuning session proposed this way (`LoopctlRunner.SpecTune`).

  One option more than `run/2`: `:prompt_transform`, a function of the prompt a case's session
  would be given, answering `{:ok, prompt}` or `{:error, reason}`. It is applied to the rendered
  prompt — never to the template that rendered it — and a case whose prompt it refuses runs no
  session. How the critic scores a proposed template revision without writing one.
  """
  @spec run_cases([Case.t()], keyword()) :: {:ok, [case_result()]} | {:error, String.t()}
  def run_cases(cases, opts \\ []) do
    scratch(opts, &run_loaded(cases, &1))
  end

  # The harness removes only what it created. A scratch directory that did not exist is made here
  # and removed whole afterwards; one that already exists — an operator's `--scratch-dir .`, a
  # directory holding anything at all — is never removed or emptied: the run gets a fresh, uniquely
  # named subdirectory inside it, and that subdirectory is all that goes.
  #
  # A missing directory's missing PARENTS are the run's too: the topmost directory this run
  # created is what goes, so `--scratch-dir /tmp/a/b/c` on a machine with no `/tmp/a` leaves no
  # `/tmp/a` behind. A kept directory is announced through `:on_scratch_dir`, the one way the
  # operator learns which subdirectory the run actually used.
  defp scratch(opts, fun) do
    ctx = context(opts)
    {work, owned} = own_scratch_dir!(ctx.scratch_dir)
    ctx = Map.merge(ctx, %{scratch_root: ctx.scratch_dir, scratch_dir: work})
    ctx = Map.put(ctx, :mcp_args, Session.mcp_isolation(write_empty_mcp_config!(ctx.scratch_dir)))

    try do
      fun.(ctx)
    after
      if ctx.keep_scratch,
        do: Keyword.get(opts, :on_scratch_dir, fn _dir -> :ok end).(work),
        else: File.rm_rf(owned)
    end
  end

  defp run_loaded(cases, ctx) do
    with {:ok, base} <- base_config(ctx),
         {:ok, fixtures} <- build_fixtures(cases, ctx) do
      Enum.reduce_while(cases, {:ok, []}, &run_in_budget(&1, &2, fixtures, base, ctx))
    end
  end

  defp run_in_budget(c, {:ok, done}, fixtures, base, ctx) do
    case session_budget(c, base, ctx) do
      :ok ->
        result = run_case(c, Map.fetch!(fixtures, c.fixture_path), base, ctx)
        {:cont, {:ok, done ++ [result]}}

      {:stop, reason} ->
        Logger.warning(reason)
        {:halt, {:error, reason}}
    end
  end

  # `:deadline_at` (US-48.13): the instant every session this run starts must be GONE by — a tuning
  # dispatch's, whose critic runs these sessions after its own. A case is started only when the
  # time to that instant, less the kill grace its session is stopped with and the clock-skew margin
  # (`Story.stop_by/3`, the same arithmetic every session's stop is aimed by), still holds the case's
  # WHOLE `wall_clock_seconds`: a critic session cut short would score the case failed for want of
  # time, not on its merits, so a pass that cannot finish is not run at all and the run stops there.
  defp session_budget(_c, _base, %{deadline_at: nil}), do: :ok

  defp session_budget(c, base, %{deadline_at: deadline} = ctx) do
    margin_s = Story.deadline_margin_s()
    need_s = c.input["wall_clock_seconds"]
    stop_by = Story.stop_by(deadline, base.kill_grace_s, margin_s)
    left_ms = DateTime.diff(stop_by, ctx.now.(), :millisecond)

    if left_ms >= need_s * 1000 do
      :ok
    else
      {:stop,
       "the eval stops before case #{c.template.id}@#{c.template.version}/#{c.name}: the " <>
         "deadline_at #{DateTime.to_iso8601(deadline)} leaves #{div(max(left_ms, 0), 1000)}s " <>
         "before its session must be stopped (#{base.kill_grace_s}s kill grace + #{margin_s}s " <>
         "clock-skew margin), less than its #{need_s}s session"}
    end
  end

  # The case's own deadline, or the run's when that is earlier: the stop every session is aimed by.
  defp bounded(fields, %{deadline_at: nil}), do: fields

  defp bounded(%{deadline_at: own} = fields, %{deadline_at: run}) do
    if own != nil and DateTime.compare(own, run) == :lt,
      do: fields,
      else: %{fields | deadline_at: run}
  end

  defp context(opts) do
    eval_dir = Path.expand(Keyword.get(opts, :eval_dir, "eval"))
    cli_dir = opts[:cli_dir] && Path.expand(opts[:cli_dir])

    %{
      prompt_transform: Keyword.get(opts, :prompt_transform),
      deadline_at: Keyword.get(opts, :deadline_at),
      runs_dir: opts[:runs_dir] && Path.expand(opts[:runs_dir]),
      eval_dir: eval_dir,
      results_dir: Path.expand(Keyword.get(opts, :results_dir, Path.join(eval_dir, "results"))),
      scratch_dir: Path.expand(Keyword.get_lazy(opts, :scratch_dir, &default_scratch/0)),
      keep_scratch: Keyword.get(opts, :keep_scratch, false),
      launcher: Path.expand(Keyword.get(opts, :launcher, @default_launcher)),
      cli_dir: cli_dir,
      grant_dir: Keyword.get_lazy(opts, :grant_dir, &Config.default_grant_dir/0),
      projects_dir: Keyword.get(opts, :projects_dir, Path.expand("~/.claude/projects")),
      path: Keyword.get_lazy(opts, :path, fn -> System.get_env("PATH", "") end),
      machine: Keyword.get_lazy(opts, :machine, fn -> machine(cli_dir) end),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0)
    }
  end

  # The MCP config every eval session is held to (`Session.mcp_isolation/1`): no server at all.
  # The operator's loopctl entry carries its own LOOPCTL_SERVER and keys in its `env`, so a
  # session environment cannot redirect it; the only way an eval session cannot reach production
  # loopctl is for that server not to be loaded (AC-48.10.5).
  @empty_mcp_config ~s({"mcpServers":{}}\n)

  defp write_empty_mcp_config!(scratch_dir) do
    path = Path.join(scratch_dir, "mcp-none.json")
    File.write!(path, @empty_mcp_config)
    path
  end

  defp default_scratch, do: Path.join(System.tmp_dir!(), scratch_name())

  defp scratch_name do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "loopctl-runner-eval-#{suffix}"
  end

  # `File.mkdir/1`, not `mkdir_p`, so that "this run made it" is decided by the filesystem in one
  # step rather than by a check that can race: `:eexist` is a directory someone else owns.
  #
  # Answers `{work, owned}`: the directory the run works in, and the topmost one it created, which
  # is all the cleanup removes.
  defp own_scratch_dir!(dir) do
    top = topmost_missing(dir)
    File.mkdir_p!(Path.dirname(dir))

    case File.mkdir(dir) do
      :ok ->
        {dir, top || dir}

      {:error, :eexist} ->
        sub = Path.join(dir, scratch_name())
        File.mkdir!(sub)
        # Someone else's directory: only the subdirectory is the run's, whatever was missing a
        # moment ago (a parent made by a racing run is that run's to remove).
        {sub, sub}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "make directory", path: dir
    end
  end

  # The topmost of `dir` and its ancestors that does not exist yet (`nil` when `dir` does): the
  # one directory removing which removes everything `own_scratch_dir!/1` is about to create.
  defp topmost_missing(dir) do
    parent = Path.dirname(dir)

    cond do
      File.exists?(dir) -> nil
      parent == dir or File.exists?(parent) -> dir
      true -> topmost_missing(parent)
    end
  end

  # The machine is what makes a `:build` result comparable at all: an implement session inherits
  # the operator's whole ~/.claude, so the same case can end differently on two machines. A run on
  # the fake CLI says so in the same field, so nobody reads its result as a model's.
  defp machine(cli_dir) do
    {:ok, host} = :inet.gethostname()
    # Relative to the checkout when the fake CLI lives in it, so a committed result names
    # `test/support/bin` and not the path of whoever recorded it.
    if cli_dir,
      do: "#{host} (offline: fake CLI #{Path.relative_to_cwd(cli_dir)})",
      else: to_string(host)
  end

  # The config every case's run is derived from, checked ONCE through the runner's own loader, so
  # a launcher the runner would refuse refuses the eval before anything is built.
  defp base_config(ctx) do
    Config.from_map(%{
      "runs_dir" => Path.join(ctx.scratch_dir, "runs"),
      "claude_projects_dir" => ctx.projects_dir,
      "grant_dir" => ctx.grant_dir,
      "claude_launcher" => ctx.launcher,
      "repos" => %{"eval" => ctx.scratch_dir},
      "branch_prefixes" => ["loop/"],
      "max_wall_clock_s" => 86_400,
      "max_turns" => 1000
    })
  end

  defp build_fixtures(cases, ctx) do
    cases
    |> Enum.map(& &1.fixture_path)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      with {:ok, manifest} <- Fixture.load(path),
           dir = Path.join([ctx.scratch_dir, "fixtures", manifest["name"]]),
           {:ok, built} <- Fixture.build(manifest, dir) do
        {:cont, {:ok, Map.put(acc, path, built)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_case(c, built, base, ctx) do
    set = "#{c.template.id}@#{c.template.version}"
    event = c.template.result_event

    {message, runner_outcome} =
      try do
        execute(c, built, base, ctx)
      rescue
        error -> {nil, "failed:eval_error #{Exception.message(error)}"}
      catch
        kind, reason -> {nil, "failed:eval_error #{Exception.format_banner(kind, reason)}"}
      end

    checks = Judge.judge(c.expectations, c.forbidden, event, message, runner_outcome)

    result =
      Result.build(%{
        case: c,
        machine: ctx.machine,
        recorded_at: ctx.now.(),
        event: event,
        message: message,
        runner_outcome: runner_outcome
      })

    path = Result.write!(result, ctx.results_dir, set, c.name)

    %{
      name: c.name,
      set: set,
      passed: Judge.passed?(checks),
      checks: checks,
      outcome: Judge.outcome(event, message, runner_outcome),
      rubric: c.expectations["rubric"],
      result_path: path
    }
  end

  defp execute(c, built, base, ctx) do
    case_dir =
      Path.join([ctx.scratch_dir, "cases", "#{c.template.id}@#{c.template.version}", c.name])

    File.mkdir_p!(case_dir)
    repo_name = c.input["repo"] |> String.split("/") |> List.last()

    with {:ok, clone} <-
           Fixture.checkout(built, c.commit, c.input["base_branch"], repo_name, case_dir),
         config = case_config(base, ctx, c, clone, repo_name, case_dir),
         {:accept, fields} <- decide(c.input, config, ctx) do
      accepted(c.template.run, c, bounded(fields, ctx), config, ctx)
    else
      {:refuse, reason, _detail} -> {nil, "refused:#{reason}"}
      {:error, reason} -> raise reason
    end
  end

  defp case_config(base, ctx, c, clone, repo_name, case_dir) do
    %{
      base
      | runs_dir: ctx.runs_dir || Path.join(case_dir, "runs"),
        repos: %{repo_name => clone},
        session_env: session_env(ctx, c, repo_name, case_dir),
        control: nil
    }
  end

  # The fake CLI is reached exactly as the suite reaches it: the REAL headless launcher, finding
  # `claude` first on the session's PATH. Passed as the repo's session environment — data on the
  # config, never a change to this BEAM's environment.
  defp session_env(%{cli_dir: nil}, _c, _repo_name, _case_dir), do: %{}

  defp session_env(ctx, c, repo_name, case_dir) do
    state = Path.join(case_dir, "fake")
    File.mkdir_p!(state)

    %{repo_name => Map.put(Case.fake_env(c, state), "PATH", ctx.cli_dir <> ":" <> ctx.path)}
  end

  # The runner's own accept decision, with a control config that accepts and connects nowhere.
  defp decide(input, config, ctx) do
    control = %ControlConfig{
      url: "",
      runner_id: "eval",
      machine: "eval",
      token_file: "",
      repos: [input["repo"]],
      max_sessions: 1,
      accepts_dispatches: true,
      min_free_disk_mb: 0
    }

    DispatchPolicy.decide(input, %{config | control: control}, %{
      draining: false,
      in_flight: 0,
      free_disk_mb: fn _path -> 0 end,
      now: ctx.now.()
    })
  end

  defp accepted(:story, c, fields, config, ctx) do
    with {:ok, story_object} <- story_object(c.input),
         {:ok, story} <- DispatchRun.story(c.input, fields, config) do
      ref = make_ref()
      me = self()

      result =
        Run.execute(config, story,
          binding: DispatchRun.binding(c.input),
          prompt:
            c.input
            |> DispatchRun.prompt(fields, story_object, c.template)
            |> transformed(ctx.prompt_transform),
          mcp_args: ctx.mcp_args,
          on_stage: fn
            {:finished, summary} -> send(me, {ref, summary})
            _event -> :ok
          end
        )

      summary =
        receive do
          {^ref, summary} -> summary
        after
          0 -> nil
        end

      {session_ended(c.input, summary), result.status}
    else
      {:error, reason} -> {nil, "refused:other #{reason}"}
    end
  end

  defp accepted(:triage, c, fields, config, ctx) do
    case TriageRun.subject(c.template, c.input) do
      {:ok, triage} ->
        result =
          TriageRun.execute(config, triage, c.input["repo"],
            binding: DispatchRun.binding(c.input),
            template: c.template,
            wall_clock_s: fields.wall_clock_s,
            max_turns: fields.max_turns,
            deadline_at: fields.deadline_at,
            mcp_args: ctx.mcp_args,
            prompt_transform: ctx.prompt_transform
          )

        {owed_message(result.run_dir), recorded_status(result.run_dir)}

      :none ->
        {nil, "refused:other the dispatch carries no triage report"}

      {:error, reason} ->
        {nil, "refused:other #{reason}"}
    end
  end

  # A `:story` run's prompt is built once its worktree exists (`DispatchRun.prompt/4`), so the
  # transform wraps that builder: applied to the prompt it renders, refusing the run when the
  # transform does.
  defp transformed(prompt, nil), do: prompt

  defp transformed(prompt, transform) do
    fn cut_from ->
      with {:ok, rendered} <- prompt.(cut_from), do: transform_prompt(transform, rendered)
    end
  end

  defp transform_prompt(transform, rendered) do
    case transform.(rendered) do
      {:ok, changed} -> {:ok, changed}
      {:error, reason} -> {:refuse, "other", "the prompt transform refused: " <> reason}
    end
  end

  defp story_object(input) do
    case DispatchRun.story_object(input) do
      {:ok, story} -> {:ok, story}
      :none -> {:error, "the dispatch carries no story"}
      {:error, detail} -> {:error, detail}
    end
  end

  # What Control would push for the run's end, from the run's own end summary.
  defp session_ended(_dispatch, nil), do: nil

  defp session_ended(dispatch, summary) do
    with true <- :session_ended in DispatchRun.end_reports(summary),
         {:ok, payload} <- DispatchRun.session_ended(dispatch, summary) do
      payload
    else
      _ -> nil
    end
  end

  # The message the run recorded as owed, exactly as a restarted Control would read and push it.
  defp owed_message(run_dir) do
    case PendingVerdicts.read(run_dir) do
      {:ok, payload} -> payload
      _ -> nil
    end
  end

  defp recorded_status(run_dir) do
    case RunState.read(run_dir) do
      {:ok, %{"status" => status}} when is_binary(status) -> status
      _ -> "failed"
    end
  end

  @doc "The names of the failing cases, as `<spec>@<version>/<case>`."
  @spec failures([case_result()]) :: [String.t()]
  def failures(results), do: for(%{passed: false} = r <- results, do: "#{r.set}/#{r.name}")

  @doc "The per-case pass/fail table."
  @spec table([case_result()]) :: String.t()
  def table(results) do
    rows =
      for r <- results do
        [
          "#{r.set}/#{r.name}",
          if(r.passed, do: "PASS", else: "FAIL"),
          r.outcome,
          detail(r)
        ]
      end

    header = ["CASE", "RESULT", "OUTCOME", "DETAIL"]
    widths = column_widths([header | rows])

    Enum.map_join([header | rows], "\n", fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
      |> String.trim_trailing()
    end)
  end

  defp column_widths(rows) do
    rows
    |> Enum.zip()
    |> Enum.map(fn column ->
      column |> Tuple.to_list() |> Enum.map(&String.length/1) |> Enum.max()
    end)
  end

  defp detail(%{passed: false, checks: checks}) do
    Enum.map_join(for({name, {:fail, why}} <- checks, do: "#{name}: #{why}"), "; ", & &1)
  end

  defp detail(%{rubric: rubric}) when is_binary(rubric), do: "rubric unjudged: read the result"
  defp detail(_result), do: ""
end
