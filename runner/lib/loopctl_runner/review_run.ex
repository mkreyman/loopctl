defmodule LoopctlRunner.ReviewRun do
  @moduledoc """
  One `review` dispatch (contract 1.21.0), run to its judgements.

  A review READS one checkpoint of a story's change thread and never writes code. So its middle is
  neither an implement run's worktree — cut on a branch of its own, kept when it holds work — nor a
  triage run's tree at the commit the checkout has out: it is a DETACHED scratch tree at the
  commit loopctl named (`review.commit_sha`), under the runner's own `runs_dir`
  (`Worktree.triage_tree_path/3`, the directory every scratch tree lives in), cut for this run and
  removed at its teardown whatever it holds. It is on no branch, so nothing a session commits there
  lands anywhere, and it is recorded `scratch` in `state.json` before it is cut, so the reaper
  removes it if this BEAM dies (`LoopctlRunner.ScratchRun` carries what it shares with a triage
  run). A checkpoint is usually a commit another machine pushed, so when the checkout does not
  hold it the story's branch is fetched in the same fetch as the base, and failing that the
  commit by its id (`Worktree.locate_checkpoint/4`); the tree it records must be the `tree_sha`
  loopctl recorded, or no session starts. The base is named to the session as the ref that
  resolves (`Worktree.locate_base/3`).

  The session runs with the posture an implement session has — `Session`'s default argv, the
  operator's inherited setup, the repo's `session_env` — with two differences, both deliberate:
  its appended system prompt is `LoopctlRunner.ReviewPrompt.system_prompt/0` rather than the
  implement one, and it holds NO subagent git grant and no `LOOP_BRANCH` (`own_worktree: false`,
  an empty branch), because nothing a review does is a commit.

  It reports through two commands its prompt names with a token only the prompt carries
  (`priv/bin/loop-finding`, `priv/bin/loop-review-verdict`), which append to `judgements.ndjson`.
  When it ends, however it ends, those are composed into the messages loopctl is sent
  (`LoopctlRunner.ReviewJudgements.compose/1`) — HERE, by the run, so a run that outlives every
  Control has still left exactly the bytes a later Control sends — and the run reports
  `{:finished, summary}` through `:on_stage`, as `LoopctlRunner.Run` does, with `kind: "review"`
  and its `run_dir` in the summary. `LoopctlRunner.DispatchRun.end_reports/1` turns that into the
  judgements and then the `session_ended` that frees the slot.

  THE DISPATCH'S `deadline_at` (contract 1.19.0) BINDS A REVIEW AS IT BINDS AN IMPLEMENT RUN:
  "A STOP BOUND: end the session by the EARLIER of your own start + `wall_clock_seconds` and this
  instant". It is checked (`Story.check_deadline/4`) before anything that costs work — the reap,
  the fetch, the cut — and again immediately before the session starts; a run past it at either
  check starts no session and ends `deadline_passed`, its scratch tree released as after any
  session. A session that starts carries it in its `Story`, so `Session` stops it in time to be gone
  by it (`Story.stop_after/4`), and one it stops ends `stopped_at_deadline`. Absent — "Present on a
  dispatch control PLACED under a claim; absent otherwise" — nothing bounds it but its wall clock.

  Unlike an implement run, a review that passed its deadline still OWES its end: whatever its
  session stated (nothing, when none started) and its `session_ended`, `crashed`
  (`DispatchRun.end_reports/1`, `DispatchRun.session_ended/2`) — a review holds no claim for the
  lease sweep to release, only the slot, which "the session's `session_ended`" frees. So its state
  is written with `RunState.update/2`, never `RunState.finish/2`, which records a `deadline_passed`
  end as settled and would leave a restart nothing to report.

  Statuses are `Run`'s: `succeeded`, `failed` (a non-zero exit, or a run that could not be
  prepared and started no session), `crashed`, `deadline_passed`, `stopped_at_deadline`, and the
  session's own stop reasons (`wall_clock_exceeded`, `max_turns_exceeded`, `escalated`, `parked`,
  `not_group_leader`).
  `escalated` should never happen — the run locks `loop-escalate` with a token it gives nobody —
  and a review that ends so anyway is reported as an implement session is, by how its session
  ended (`DispatchRun.session_ended/2`), with what it said logged as an error by `Control`.
  """

  require Logger

  alias LoopctlRunner.{
    ClaimEnded,
    Config,
    DispatchRun,
    Owner,
    ReviewJudgements,
    ReviewPrompt,
    Run,
    RunState,
    ScratchRun,
    Session,
    Story,
    Trace,
    TriageVerdict,
    Worktree
  }

  @typedoc """
  What a review is run from: the dispatch's story and review objects, and what the policy
  resolved — the repo's name and checkout, the dispatch's branch and base, and the budgets.
  """
  @type work :: %{
          required(:story) => map(),
          required(:review) => map(),
          required(:repo) => String.t(),
          required(:repo_path) => String.t(),
          required(:dispatch_repo) => String.t(),
          required(:branch) => String.t(),
          required(:base) => String.t(),
          required(:wall_clock_s) => pos_integer(),
          required(:max_turns) => pos_integer(),
          # The dispatch's stop bound (contract 1.19.0), as the policy parsed it; nil or absent
          # when the dispatch carries none.
          optional(:deadline_at) => DateTime.t() | nil
        }

  @doc """
  Runs the review and returns its result.

  Options: `:binding` (the dispatch this run answers, written into `state.json` first),
  `:on_stage` (called with `{:started, %{run_id, run_dir}}` once the run directory exists — BEFORE
  its state is written, for `TriageRun`'s reason: a state naming a live owner that nobody knows the
  directory of is a run nobody can close — and `{:finished, summary}` however the run ends, a kill
  aside), `:model`, `:run_id`.
  """
  @spec execute(Config.t(), work(), keyword()) :: map()
  def execute(%Config{} = config, work, opts \\ []) do
    run_id = Keyword.get_lazy(opts, :run_id, &Session.uuid4/0)

    result =
      case Owner.current() do
        {:ok, owner} ->
          start(config, work, run_id, owner, opts)

        # Nothing written: a run recorded without its owner's start reads as an orphan, and the
        # next run's reap would kill its session.
        {:error, :no_start} ->
          %{
            run_dir: nil,
            status: "failed",
            session: nil,
            error: "this BEAM's own start time could not be read"
          }
      end

    unprepared(result, work, opts)
    Run.stage(opts, {:finished, summary(result)})
    Map.put(result, :run_id, run_id)
  end

  # A review that started no session — its commit unfetchable, its tree not the one loopctl
  # recorded, its run directory unwritable — will not start one on this dispatch however long it
  # waits, so it is said ONCE, here, as an error naming the dispatch and the checkpoint. Its
  # `session_ended` still goes, with the reason a session that never ran gets
  # (`DispatchRun.session_ended/2`).
  defp unprepared(%{status: "failed", session: nil, error: error}, work, opts) do
    id = Keyword.get(opts, :binding, %{})["dispatch_id"]

    Logger.error(
      "the review of dispatch #{id} started no session for checkpoint " <>
        "#{work.review["checkpoint_id"]} (commit #{work.review["commit_sha"]}): #{error}",
      dispatch_id: id
    )
  end

  # A moment, not a failure: loopctl's placement ran out before the session could start. Said once,
  # as a warning, and its `session_ended` still goes (`DispatchRun.end_reports/1`).
  defp unprepared(%{status: "deadline_passed", error: detail}, work, opts) do
    id = Keyword.get(opts, :binding, %{})["dispatch_id"]

    Logger.warning(
      "the review of dispatch #{id} started no session for checkpoint " <>
        "#{work.review["checkpoint_id"]}: #{detail}; its session_ended is still sent",
      dispatch_id: id
    )
  end

  defp unprepared(_result, _work, _opts), do: :ok

  defp start(config, work, run_id, owner, opts) do
    # THE deadline guard before anything that costs work: the reap can fetch, and the run mints,
    # fetches and cuts. Judged again immediately before the session (`judged_session/4`). The run
    # directory and its state are written either way: they are what its end is reported from.
    deadline = check_deadline(config, work)
    if deadline == :ok, do: ScratchRun.reap(config, owner, "review")
    run_dir = run_dir(config, work, run_id)
    File.mkdir_p!(run_dir)
    Run.stage(opts, {:started, %{run_id: run_id, run_dir: run_dir}})

    RunState.update(
      run_dir,
      Keyword.get(opts, :binding, %{})
      |> Map.merge(%{
        "run_id" => run_id,
        "kind" => "review",
        "review" => work.review,
        "repo" => work.repo,
        "repo_path" => work.repo_path,
        "status" => "running"
      })
      |> Map.merge(owner)
    )

    {:ok, trace} = Trace.start_link(Path.join(run_dir, "trace.ndjson"), run_id)

    seq =
      Trace.emit(trace, "review.started", nil, %{
        "review_id" => work.review["review_id"],
        "round" => work.review["round"],
        "checkpoint_id" => work.review["checkpoint_id"],
        "commit_sha" => work.review["commit_sha"]
      })

    result =
      case deadline do
        :ok ->
          guarded_run(config, work, run_dir, run_id, trace, seq, opts)

        {:passed, detail} ->
          deadline_passed(trace, seq, detail)
      end

    result = Map.put(result, :run_dir, run_dir)
    finish(trace, seq, run_dir, result)
    result
  end

  defp guarded_run(config, work, run_dir, run_id, trace, seq, opts) do
    run(config, work, run_dir, run_id, trace, seq, opts)
  catch
    # EVERY way out, as `Run` and `TriageRun` do: a run recorded `running` with no end is
    # indistinguishable from one still going, and its judgements would never be composed.
    kind, reason ->
      %{status: "crashed", session: nil, error: Run.crash_error(kind, reason)}
  end

  defp check_deadline(config, work),
    do:
      Story.check_deadline(
        Map.get(work, :deadline_at),
        work.wall_clock_s,
        config,
        DateTime.utc_now()
      )

  defp deadline_passed(trace, seq, detail) do
    Trace.emit(trace, "review.deadline_passed", seq, %{"error" => detail})
    %{status: "deadline_passed", session: nil, error: detail}
  end

  # The escalate token is minted and handed to NOBODY: `loop-escalate` requires it once it exists,
  # so neither the session nor a subagent can end a review by escalating. A review claims nothing,
  # so it has no stage to escalate through; a session that cannot review says why in its verdict
  # (`ReviewPrompt.system_prompt/0`).
  defp run(config, work, run_dir, run_id, trace, seq, opts) do
    where = %{run_dir: run_dir, run_id: run_id, trace: trace, seq: seq}

    with {:ok, token} <- prepared(ReviewJudgements.mint_token(run_dir)),
         {:ok, _locked} <- prepared(TriageVerdict.mint_escalate_token(run_dir)),
         :ok <-
           prepared(
             ReviewJudgements.write_form(run_dir, Map.take(work.review, ~w(round checkpoint_id)))
           ),
         {:ok, sha, base_fetched} <- checkpoint(work, trace, seq),
         {:ok, tree} <- cut(work, sha, where, config) do
      try do
        missing = ScratchRun.submodules(tree, where)
        base = base_ref(work, base_fetched, trace, seq)
        story = session_story(work, token, base, missing)
        write_story(run_dir, story, token)
        judged_session(config, work, story, Map.put(where, :tree, tree.path), opts)
      after
        ScratchRun.release(config, tree, where, "review")
      end
    end
  end

  @claim_ended "loopctl ended the claim this review was dispatched under before its session started"

  # THE deadline guard before the session, immediately before it starts: fetching, cutting and
  # syncing submodules take time, and a session started past it would be stopped almost at once.
  # Nothing checks after it: a session started here is bounded by its own stop timer
  # (`Story.stop_after/4`, from the `deadline_at` its story carries). Inside the tree's `try`, so the
  # tree is released as after any session.
  #
  # Beside it, the CLAIM (contract 1.22.0): one loopctl ended before the session started
  # (`LoopctlRunner.ClaimEnded`) gets none. The review still ends with its `session_ended`, which
  # is what frees the slot; Control sends none of its judgements.
  defp judged_session(config, work, story, where, opts) do
    if ClaimEnded.ended?(config.runs_dir, Keyword.get(opts, :binding, %{})) do
      Trace.emit(where.trace, "review.claim_ended", where.seq, %{})
      %{status: "claim_ended", session: nil, error: @claim_ended}
    else
      case check_deadline(config, work) do
        :ok ->
          session = session(config, story, where, opts)
          %{status: Run.session_status(session), session: session, error: session_error(session)}

        {:passed, detail} ->
          deadline_passed(where.trace, where.seq, detail)
      end
    end
  end

  defp prepared(:ok), do: :ok
  defp prepared({:ok, value}), do: {:ok, value}

  defp prepared({:error, reason}),
    do: failed("the review could not be prepared: #{format(reason)}")

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)

  defp failed(error), do: %{status: "failed", session: nil, error: error}

  # The commit loopctl named, found in the checkout or fetched from the story's branch in the same
  # fetch as the base, and the tree it records checked against the one loopctl recorded: a session
  # judging other content than the checkpoint's would report findings about code nobody wrote.
  defp checkpoint(work, trace, seq) do
    commit = work.review["commit_sha"]

    with {:ok, sha, base_fetched} <-
           located(Worktree.locate_checkpoint(work.repo_path, commit, work.branch, work.base)),
         :ok <- same_tree(work, sha) do
      Trace.emit(trace, "review.checkpoint", seq, %{"commit_sha" => sha})
      {:ok, sha, base_fetched}
    else
      %{error: error} = failure ->
        Trace.emit(trace, "review.checkpoint_failed", seq, %{"error" => error})
        failure
    end
  end

  defp located({:ok, sha, base_fetched}), do: {:ok, sha, base_fetched}
  defp located({:unreadable, reason}), do: failed(reason)
  defp located({:error, reason}), do: failed(reason)

  defp same_tree(work, sha) do
    expected = work.review["tree_sha"]

    case Worktree.commit_tree(work.repo_path, sha) do
      {:ok, ^expected} ->
        :ok

      {:ok, other} ->
        failed("commit #{sha} records tree #{other}, not the #{expected} loopctl recorded")

      {:error, out} ->
        failed("the tree of commit #{sha} could not be read: #{out}")
    end
  end

  # Recorded BEFORE it is cut, as every tree is, so a BEAM that dies mid-run leaves it where the
  # reaper looks — and `scratch`, which is what makes the reaper remove it whatever it holds.
  defp cut(work, sha, where, config) do
    path = Worktree.triage_tree_path(config.runs_dir, work.repo_path, where.run_id)
    tree = %{repo_path: work.repo_path, path: path, base: sha}
    ScratchRun.record_tree(where.run_dir, tree, "creating")

    case Worktree.create_detached_at(work.repo_path, path, sha) do
      {:ok, ^sha} ->
        ScratchRun.record_tree(where.run_dir, tree, "created")

        Trace.emit(where.trace, "worktree.created", where.seq, %{
          "path" => path,
          "commit_sha" => sha
        })

        {:ok, tree}

      {:error, reason, :tree_left} ->
        ScratchRun.give_back_left(config, tree, where, "review")
        failed(reason)

      {:error, reason} ->
        ScratchRun.record_tree(where.run_dir, tree, "not_prepared")
        Trace.emit(where.trace, "worktree.failed", where.seq, %{"error" => reason})
        failed(reason)
    end
  end

  # The ref the session measures the change against, named as it resolves in the scratch tree —
  # which shares the checkout's refs: `origin/<base>` once fetched, so a checkout whose local base
  # is behind (or absent) does not make the session judge commits the story never made. Fetched
  # with the checkpoint (`checkpoint/3`), so it is only resolved here.
  defp base_ref(work, base_fetched, trace, seq) do
    case Worktree.locate_base(work.repo_path, work.base, base_fetched) do
      {:ok, ref} ->
        Trace.emit(trace, "review.base", seq, %{"ref" => ref})
        ref

      :none ->
        Trace.emit(trace, "review.base_missing", seq, %{"base" => work.base})
        nil
    end
  end

  # A Story because that is what `Session` runs, built for a session that holds no branch: an
  # empty `branch` is what keeps `LOOP_BRANCH`, and so `loop-push`, away from it.
  defp session_story(work, token, base, missing) do
    %Story{
      id: DispatchRun.story_id(work.story["id"]),
      repo: work.repo,
      repo_path: work.repo_path,
      base: "",
      branch: "",
      prompt:
        ReviewPrompt.build(work.story, work.review, %{
          repo: work.dispatch_repo,
          branch: work.branch,
          base: base || work.base,
          token: token
        }) <>
          base_note(base, work.base) <>
          ScratchRun.missing_note(
            missing,
            "not the change's: report no finding about their absence."
          ),
      wall_clock_s: work.wall_clock_s,
      max_turns: work.max_turns,
      model: nil,
      # What `Session` stops the session in time for (`Story.stop_after/4`).
      deadline_at: Map.get(work, :deadline_at)
    }
  end

  # Said only when no ref for the base resolves, so the session measures the commit by what it
  # carries rather than against a name git will not read.
  defp base_note(nil, base) do
    "\nThe runner could NOT resolve #{base} in this checkout, neither as fetched from origin nor " <>
      "locally: read what #{base} names from the commit's own history instead.\n"
  end

  defp base_note(_ref, _base), do: ""

  # claude-config's loop mode reads LOOP_STORY_FILE, so every session's run directory has one.
  # Written with the judgement token REDACTED from the prompt: the token belongs in the session's
  # prompt and nowhere a subagent's file tools can read, and story.json is a file any of them can.
  defp write_story(run_dir, story, token) do
    map = Story.to_map(%{story | prompt: String.replace(story.prompt, token, "<redacted>")})
    File.write!(Path.join(run_dir, "story.json"), JSON.encode!(map))
  end

  defp session(config, story, where, opts) do
    Session.run(
      config: config,
      story: %{story | model: Keyword.get(opts, :model)},
      worktree: where.tree,
      # No branch of its own, so no subagent git grant: nothing a review does is a commit.
      own_worktree: false,
      run_dir: where.run_dir,
      trace: where.trace,
      parent: where.seq,
      system_prompt: ReviewPrompt.system_prompt(),
      env: Config.session_env_for(config, story.repo, story.id, where.run_id)
    )
  catch
    # Only :exit, as `Run.run_session/7` does: the session's monitor dying is a crash of the
    # session, and whatever it stated before that is still composed and sent.
    :exit, reason ->
      Trace.emit(where.trace, "session.crashed", where.seq, %{"reason" => inspect(reason)})
      {:session_failed, inspect(reason)}
  end

  defp session_error({:session_failed, detail}), do: "session monitor crashed: #{detail}"
  defp session_error(_session), do: nil

  # Composed HERE, before anything is told: see the moduledoc. Guarded, like every end.
  defp finish(trace, seq, run_dir, result) do
    composed =
      case ReviewJudgements.compose(run_dir) do
        {:ok, messages} ->
          length(messages)

        {:error, why} ->
          Logger.error("the review run's judgements could not be composed: #{why}")
          nil
      end

    Trace.emit(trace, "review.finished", seq, %{"status" => result.status, "messages" => composed})

    Trace.close(trace)

    # `update`, never `RunState.finish/2`: a review past its deadline still owes its end (moduledoc).
    RunState.update(run_dir, %{
      "status" => result.status,
      "finished_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    })

    :ok
  rescue
    error -> Logger.error("the review run's end could not be recorded: #{inspect(error)}")
  catch
    kind, reason ->
      Logger.error("the review run's end could not be recorded: #{inspect({kind, reason})}")
  end

  @doc """
  What the run's end is reported from: `kind: "review"`, which is what gives it its judgements and
  its `session_ended` (`DispatchRun.end_reports/1`), the run directory they are read from, and the
  status `DispatchRun.session_ended/2` reads the reason off.
  """
  @spec summary(map()) :: map()
  def summary(result) do
    session = if is_map(result.session), do: result.session

    %{
      kind: "review",
      run_dir: result.run_dir,
      status: result.status,
      error: result.error,
      exit_reason: session && Atom.to_string(session.reason),
      exit_status: session && session.exit_status,
      escalations: if(result.run_dir, do: Run.escalations(result.run_dir), else: [])
    }
  end

  defp run_dir(config, work, run_id) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    story = String.downcase(work.story["id"])
    Path.join(config.runs_dir, "review-#{story}-#{stamp}-#{binary_part(run_id, 0, 8)}")
  end
end
