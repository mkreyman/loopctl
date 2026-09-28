defmodule LoopctlRunner.TriageRun do
  @moduledoc """
  One triage dispatch, run to a verdict (design §4).

  Shaped like `LoopctlRunner.Run` and deliberately not sharing it: an implement run's whole
  middle is a worktree — created, branched, torn down, kept when it holds work — and a triage run's
  is a DETACHED worktree at the commit the checkout has out: the repo's one reused triage tree,
  refreshed to that commit for each run that holds its lock, or — when a live run holds it — a tree
  of this run's own, removed after it whatever it holds. Both live under the runner's `runs_dir`
  (`Worktree.triage_tree_path/2` and `/3`), and the session works there rather than in the
  operator's live checkout, so nothing it or a lens it dispatches does lands in his working tree,
  and the checkout's branch is never touched. It states one verdict. What the two share is the run directory, the state file,
  the trace, the process-group discipline and `LoopctlRunner.Worktree`, which is why those come
  from the same modules.

  The order matters and each step is a precondition of the next:

    1. the run directory, ANNOUNCED to whoever is supervising this run (`:on_start`), and then
       `state.json`, so a crash is attributable before anything runs. That order is the whole of
       it: a state naming a live owner that nobody knows the directory of is a run no one can
       close and nothing will reap;
    2. the two tokens (`LoopctlRunner.TriageVerdict.mint_token/1` and `mint_escalate_token/1`),
       minted BEFORE the prompt is built because the prompt carries them — they are what make the
       verdict and the escalation the SESSION's rather than something a subagent it dispatches
       could state;
    3. the detached worktree the session will run in, recorded in `state.json` before it is cut
       so the reaper finds it if this BEAM dies; a checkout git will not read is
       `checkout_unreadable`, a tree that could not be cut is the runner's own
       `no_verdict_written`. From the moment the cut returns, everything is inside the guard that
       gives the tree back: the entry recorded `created`, then the tree's submodules, then the
       prompt, from the fenced report, the lenses this run actually grants and the submodule
       paths that could not be initialised;
    4. the session, with `LoopctlRunner.TriageTools`' contained set rather than the implement
       one;
    5. the verdict, read and validated against the contract before anything believes it;
    6. the outcome recorded as the MESSAGE that states it (`LoopctlRunner.PendingVerdicts`),
       beside the verdict and before anything is told about it. The outcome reaches Control as a
       message and a message reaches nobody when none is registered, so a run that outlives every
       Control would otherwise have done the work and left loopctl waiting on the dispatch for the
       life of the claim.

  The outcome is one of `{:verdict, verdict}`, `{:incomplete, reason, detail}`, `{:error, reason}`
  or `{:deadline_passed, detail}`. The last is a run whose dispatch's `deadline_at` had passed when
  it began (`Story.check_deadline/4`), when it reaps, mints, cuts and launches nothing, or by the
  time its session would start, checked immediately before it (its tree is released as after any
  session): it records its state `deadline_passed` with `terminal_reported` `skipped`
  (`RunState.finish/2`) and no message — after its deadline the claim is loopctl's lease sweep's
  to release, and there is no verdict to state. The incomplete reasons come from the vendored contract's
  `RunnerTriageVerdictMessage.incomplete` enum (its non-null members; 1.9.2) and are read from it rather than repeated
  here — `incomplete_reasons/0` is the list, and a value outside it raises at compile time.
  Four of the five describe what the SESSION did: `session_crashed`, `wall_clock_exceeded`,
  `no_verdict_written` (including an escalation, whose own words go in the detail), and
  `verdict_invalid`.

  The fifth, `checkout_unreadable`, is the RUNNER's, and the distinction it turns on is whether
  the cause was verified. An escalating session says only that it could not work at all and never
  why, so naming a cause there would send a reader to a checkout that is fine. `checkout/2` is
  different: it looked, so a repo with no configured checkout or a path that is not a directory
  is reported as `checkout_unreadable` and reaches loopctl as a finished run. That mapping was
  missing while the enum was transcribed out of a commit message instead of read from the file,
  and the cost was not cosmetic — the condition returned `{:error, _}`, which has no wire form, so
  the dispatch it answers would have stayed in flight for ever.

  A verdict file the runner could NOT READ reports by what is actually at the path: a regular file
  is something the session wrote, so `verdict_invalid`; anything else, or nothing, is
  `no_verdict_written`. A run the runner could not PREPARE — a token it could not write, the same
  failing volume seen one step earlier — is `no_verdict_written` too, because by then the dispatch
  is already this runner's and an outcome with no wire form would strand it. What stays
  `{:error, _}` is the one thing that is not an outcome at all — a budget over this runner's
  configured ceiling, where the dispatch is refused and no run begins. That belongs to
  `RunnerDispatchReply` (`wall_clock_exceeds_limit`, `max_turns_exceeds_limit`), which is a
  refusal of the dispatch rather than a report about a run.

  Every detail is cut to the contract's `maxLength` before it leaves, in codepoints.
  """

  require Logger

  alias LoopctlRunner.{
    ClaimEnded,
    Config,
    Contract,
    Owner,
    PendingVerdicts,
    Run,
    RunState,
    ScratchRun,
    Session,
    Story,
    Trace,
    TriageDispatch,
    TriagePrompt,
    TriageTools,
    TriageVerdict,
    Uuid,
    Worktree,
    WorktreeLock
  }

  # Read from the vendored contract at COMPILE time, not repeated: the last time this repo held
  # its own copy of this enum, the copy was one value short and nothing could see it.
  # `null` is a MEMBER of that enum since 1.9.2 — the field is nullable, and an enum that did not
  # list null refused the explicit null an emitter sends beside a real verdict. It is not a
  # reason, so it is not in this list: what this module reports is always one of the strings.
  @incomplete_reasons Contract.schema_def("RunnerTriageVerdictMessage")
                      |> get_in(["properties", "incomplete", "enum"])
                      |> Enum.reject(&is_nil/1)

  for reason <- ~w(session_crashed wall_clock_exceeded checkout_unreadable no_verdict_written
                   verdict_invalid) do
    unless reason in @incomplete_reasons do
      raise "this module reports #{reason}, which the vendored contract does not publish"
    end
  end

  @doc """
  The incomplete REASONS the vendored contract publishes: the enum's non-null members.

  `null` is in that enum since 1.9.2 and is not a reason — it is how a message that carries a
  verdict says it carries no incomplete.
  """
  @spec incomplete_reasons() :: [String.t()]
  def incomplete_reasons, do: @incomplete_reasons

  # The detail is BOUNDED by the same file, and two of its producers are wildly over: an
  # escalation's own words are admitted up to 4000 characters by `Session.escalation_data/1`, and
  # an exit reason is a formatted term of no fixed size. Over the cap the whole message is refused
  # invalid_payload, which `x-connection.permanent_errors` makes permanent, so the run's only
  # output is discarded rather than retried — the detail is the least important field in the
  # message and would take the verdict down with it.
  # `|| raise`, for the same reason the enum above has its guard: `get_in/2` answers nil rather
  # than raising, and a nil cap makes `Enum.take/2` raise inside every incomplete outcome — so a
  # vendored contract that renamed `detail` would turn each one into a crash caught by the run's
  # own guard, which is `{:error, _}`, which has no wire form. The hole this module closes would
  # reopen at vendor time with nothing naming it.
  @max_detail Contract.schema_def("RunnerTriageVerdictMessage")
              |> get_in(["properties", "detail", "maxLength"]) ||
                raise("the vendored contract publishes no maxLength for a triage verdict detail")

  # Codepoints, not graphemes: the schema's maxLength is the looser count and loopctl refuses by
  # the stricter one, exactly as `DispatchRun.cap_reason/1` already does for a stage reason.
  defp detail(text) do
    text |> String.codepoints() |> Enum.take(@max_detail) |> Enum.join()
  end

  # The one constructor: every reason leaves through here, so a reason added later cannot forget
  # the cap by being written as a bare tuple. NOT called `incomplete/2` — that arity is the
  # dispatcher over the session's ending, and a second clause of it would have been unreachable,
  # sending every reason out as no_verdict_written.
  defp reported(reason, detail), do: {:incomplete, reason, detail(detail)}

  @doc "The detail cap the vendored contract publishes."
  @spec max_detail() :: pos_integer()
  def max_detail, do: @max_detail

  @type outcome ::
          {:verdict, map()}
          | {:incomplete, String.t(), String.t()}
          | {:error, String.t()}
          | {:deadline_passed, String.t()}

  @type result :: %{
          run_id: String.t(),
          run_dir: String.t(),
          outcome: outcome(),
          session: Session.result() | nil
        }

  @doc """
  Runs `triage` (a `RunnerTriage` object) for `repo` in its local checkout.

  Options: `:binding` (written into `state.json`, the dispatch this run answers), `:on_start`
  (called with `%{run_id:, run_dir:}` the moment the run directory and its state exist), `:lenses`
  (default `TriageTools.lenses/0`), `:wall_clock_s`, `:max_turns`, `:model`, `:run_id`, and
  `:deadline_at` (the dispatch's stop bound, a `DateTime`: the session is stopped in time to be gone
  by it, `Story.stop_after/4`, and a run past `Story.check_deadline/4` when it begins, or when its
  session would start, ends `{:deadline_passed, _}` having started no session).

  `:on_start` is what makes this run's directory reachable by whoever is supervising it BEFORE the
  run ends, which is the only moment that matters when it does not end normally: a task killed
  from outside leaves a state at `running` with a live owner, and `Runs.in_flight/2` counts such a
  run for the life of the BEAM. It is called before that state is written, so there is no instant
  at which such a state exists and nobody knows where it is. It mirrors the `{:started, _}` event
  `Run.execute/3` reports.
  """
  @spec execute(Config.t(), map(), String.t(), keyword()) :: result()
  def execute(%Config{} = config, triage, repo, opts \\ []) do
    run_id = Keyword.get_lazy(opts, :run_id, &Session.uuid4/0)

    # The owner before anything is written: a state recorded without its start reads as an
    # orphan, and the next implement dispatch's reap would kill this run's session.
    with {:ok, record} <- record_id(triage),
         {:ok, owner} <- owner() do
      start(config, triage, repo, record, run_id, owner, opts)
    else
      {:error, reason} -> %{run_id: run_id, run_dir: nil, session: nil, outcome: {:error, reason}}
    end
  end

  defp owner do
    case Owner.current() do
      {:ok, owner} -> {:ok, owner}
      {:error, :no_start} -> {:error, "this BEAM's own start time could not be read"}
    end
  end

  # A uuid, checked before it is ever part of a path. This module does not validate the triage
  # object — the accept path does — and a record_id carrying `/` or `..` would put the run
  # directory outside runs_dir, where RunState.all/1 and the reaper's glob cannot see it: a run
  # nothing reaps and nothing reports.
  defp record_id(%{"record_id" => id}) when is_binary(id) do
    if Uuid.valid?(id),
      do: {:ok, String.downcase(id)},
      else: {:error, "record_id #{inspect(id)} is not a uuid"}
  end

  defp record_id(_triage), do: {:error, "the triage object names no record_id"}

  defp start(config, triage, repo, record, run_id, owner, opts) do
    # THE deadline guard before anything that costs work: the reap can fetch, and the run mints,
    # fetches and cuts. Judged again immediately before the session (`judge/8`).
    deadline = check_deadline(config, opts)
    _reaped = reap(config, owner, deadline)
    run_dir = run_dir(config, record, run_id)

    # BEFORE the state, not after: `state.json` at `running` carries this BEAM's live owner, so a
    # task killed between writing it and announcing it leaves a run nothing can close — the
    # supervisor never learned the directory, `Runs.in_flight/2` counts it for the life of the
    # BEAM, and the reaper skips it because the owner really is alive. Announced first, the worst a
    # kill leaves is an empty directory, which nothing counts and nothing has to clean up.
    announce(opts, %{run_id: run_id, run_dir: run_dir})

    RunState.update(
      run_dir,
      Keyword.get(opts, :binding, %{})
      |> Map.merge(%{
        "run_id" => run_id,
        "kind" => "triage",
        "record_id" => record,
        "repo" => repo,
        "status" => "running"
      })
      # Without the owner, Reaper.orphan? reads a LIVE triage run as an orphan — every state
      # lacking beam_os_pid is — so the next implement dispatch reaps first and kills its session.
      # The verdict is then never stated, by the runner's own hand.
      |> Map.merge(owner)
    )

    {:ok, trace} = Trace.start_link(Path.join(run_dir, "trace.ndjson"), run_id)
    seq = Trace.emit(trace, "triage.started", nil, %{"record_id" => record, "repo" => repo})

    result =
      case deadline do
        :ok ->
          # The owner rides in the options to the reused tree's lock (`claim_tree/4`), which
          # records it.
          guarded_run(
            config,
            triage,
            repo,
            run_dir,
            run_id,
            trace,
            seq,
            Keyword.put(opts, :owner, owner)
          )

        {:passed, detail} ->
          Trace.emit(trace, "triage.deadline_passed", seq, %{"error" => detail})
          %{run_id: run_id, run_dir: run_dir, session: nil, outcome: {:deadline_passed, detail}}
      end

    finish(trace, seq, run_dir, result, Keyword.get(opts, :binding, %{}))
    result
  end

  defp guarded_run(config, triage, repo, run_dir, run_id, trace, seq, opts) do
    run(config, triage, repo, run_dir, run_id, trace, seq, opts)
  catch
    # EVERY way out, as `Run.execute/3` does: Session.run/1 exits on a launch or monitor failure by
    # design, and a raise anywhere in here would otherwise leave the run recorded "running" with no
    # outcome and no triage.finished — indistinguishable from one still going, and now un-reaped
    # too, because the owner this run records is alive.
    kind, reason ->
      %{
        run_id: run_id,
        run_dir: run_dir,
        session: nil,
        outcome: {:error, "the run failed: #{Exception.format(kind, reason, [])}"}
      }
  end

  # What an implement run does before it starts (`ScratchRun.reap/3` says why, and guards it). A
  # run past its deadline does no work at all, and a reap is work.
  defp reap(_config, _owner, {:passed, _detail}), do: :skipped
  defp reap(config, owner, :ok), do: ScratchRun.reap(config, owner, "triage")

  # Guarded, and the guard is the point: this runs OUTSIDE the try below, before the state or the
  # trace exists, so a callback that raises would take the run down before it had written anything
  # about itself. Whoever is listening loses the early notice; the run goes on, and its outcome
  # still reports.
  defp announce(opts, run) do
    case Keyword.get(opts, :on_start) do
      nil -> :ok
      on_start when is_function(on_start, 1) -> on_start.(run)
    end
  rescue
    error -> Logger.error("the triage run's start could not be announced: #{inspect(error)}")
  catch
    kind, reason ->
      Logger.error("the triage run's start could not be announced: #{inspect({kind, reason})}")
  end

  # Guarded too: `RunState.update/2` writes and renames, and a full volume or a run directory the
  # session removed would otherwise raise HERE — leaving state.json at "running" with this BEAM's
  # live owner recorded, which is precisely the combination the reaper will never clean up.
  defp finish(trace, seq, run_dir, result, binding) do
    name = outcome_name(result.outcome)
    record(run_dir, binding, result.outcome)
    Trace.emit(trace, "triage.finished", seq, %{"outcome" => name})
    Trace.close(trace)

    # A run that passed its deadline owes nothing, and `RunState.finish/2` says so in this write.
    RunState.finish(run_dir, %{
      "status" => name,
      "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    :ok
  rescue
    error -> Logger.error("the triage run's end could not be recorded: #{inspect(error)}")
  catch
    kind, reason ->
      Logger.error("the triage run's end could not be recorded: #{inspect({kind, reason})}")
  end

  defp run(config, triage, repo, run_dir, run_id, trace, seq, opts) do
    config
    |> prepare_and_judge(triage, repo, run_dir, run_id, trace, seq, opts)
    |> result(run_id, run_dir)
  end

  defp prepare_and_judge(config, triage, repo, run_dir, run_id, trace, seq, opts) do
    with {:ok, name, path} <- checkout(config, repo),
         :ok <- budgets(config, opts),
         {:ok, token} <- mint(run_dir, &TriageVerdict.mint_token/1),
         {:ok, escalate} <- mint(run_dir, &TriageVerdict.mint_escalate_token/1),
         {:ok, tree} <- detached_tree(config, path, run_dir, run_id, trace, seq, opts[:owner]) do
      # EVERYTHING after a successful cut is inside this try, so no way out of it — a return, a
      # raise, an exit — leaves the tree or its lock behind. `created` is recorded FIRST, before
      # the submodules: a raise in them is a tree that exists, which the release path removes or
      # releases, and never the `not_prepared` of a tree that was not cut.
      try do
        prompt =
          prepared(fn ->
            ScratchRun.record_tree(run_dir, tree, "created")

            missing =
              ScratchRun.submodules(tree, %{
                run_dir: run_dir,
                run_id: run_id,
                trace: trace,
                seq: seq
              })

            lenses = Keyword.get(opts, :lenses, TriageTools.lenses())

            args = [
              token: token,
              escalate_token: escalate,
              lenses: lenses,
              missing_submodules: missing
            ]

            {:ok, TriagePrompt.build(triage, repo, args)}
          end)

        with {:ok, prompt} <- prompt do
          judge(config, prompt, {name, path, tree}, run_dir, run_id, trace, seq, opts)
        end
      after
        release_tree(config, tree, run_dir, run_id, trace, seq)
      end
    end
  end

  defp result(%{} = result, _run_id, _run_dir), do: result

  defp result(failure, run_id, run_dir) do
    case failure do
      {:unreadable, reason} ->
        %{
          run_id: run_id,
          run_dir: run_dir,
          session: nil,
          outcome: reported("checkout_unreadable", reason)
        }

      {:unreported, reason} ->
        %{
          run_id: run_id,
          run_dir: run_dir,
          session: nil,
          outcome: reported("no_verdict_written", "the run could not be prepared: #{reason}")
        }

      {:error, reason} ->
        %{run_id: run_id, run_dir: run_dir, session: nil, outcome: {:error, reason}}
    end
  end

  @claim_ended "loopctl ended the claim this triage was dispatched under before its session started"

  # THE deadline guard before the session: minting, fetching and cutting take time, and a session
  # started past it would be stopped at once. Nothing checks after it: a session started here is
  # bounded by its own stop timer (`Story.stop_after/4`). Inside the tree's `try`, so the tree is
  # released as after any session.
  #
  # Beside it, the CLAIM (contract 1.22.0): one loopctl ended before the session started
  # (`LoopctlRunner.ClaimEnded`) gets none, and its outcome says so; Control never sends it.
  defp judge(config, prompt, tree, run_dir, run_id, trace, seq, opts) do
    if ClaimEnded.ended?(config.runs_dir, Keyword.get(opts, :binding, %{})) do
      Trace.emit(trace, "triage.claim_ended", seq, %{})
      outcome = {:incomplete, "no_verdict_written", @claim_ended}
      %{run_id: run_id, run_dir: run_dir, session: nil, outcome: outcome}
    else
      case check_deadline(config, opts) do
        :ok ->
          judge_session(config, prompt, tree, run_dir, run_id, trace, seq, opts)

        {:passed, detail} ->
          Trace.emit(trace, "triage.deadline_passed", seq, %{"error" => detail})
          %{run_id: run_id, run_dir: run_dir, session: nil, outcome: {:deadline_passed, detail}}
      end
    end
  end

  defp check_deadline(config, opts) do
    Story.check_deadline(
      Keyword.get(opts, :deadline_at),
      wall_clock_s(config, opts),
      config,
      DateTime.utc_now()
    )
  end

  defp judge_session(config, prompt, {name, path, tree}, run_dir, run_id, trace, seq, opts) do
    # Caught HERE, not only by the outer guard: Session.run/1 exits when its monitor dies, and the
    # outer catch would return {:error, _} without ever reading the run directory — throwing away a
    # verdict the session had already written and linked into place. `Run` catches the same exit
    # locally for the same reason.
    session =
      try do
        session(config, prompt, {name, path, tree.path}, run_dir, run_id, trace, seq, opts)
      catch
        # Only :exit, as `Run.run_session/7` does. A raise in here is the runner's own bug and
        # belongs to the outer guard, which reports it as an error rather than dressing it up
        # as something the session did.
        :exit, reason ->
          Trace.emit(trace, "session.crashed", seq, %{"reason" => inspect(reason)})
          {:session_failed, inspect(reason)}
      end

    %{
      run_id: run_id,
      run_dir: run_dir,
      # `:session` is the session's own report or nil; a failure to supervise it is not a
      # report, and it is already carried in the outcome.
      session: if(match?({:session_failed, _}, session), do: nil, else: session),
      outcome: outcome(run_dir, session)
    }
  end

  # Preparing the run happens after the run directory and state.json exist, so the dispatch is
  # already this runner's: a raise here (a state write on a full volume, a prompt that will not
  # build) is the runner failing to prepare the run, which has a wire form — `no_verdict_written`,
  # as `mint/2` reports it — where the outer guard's `{:error, _}` has none.
  defp prepared(fun) do
    fun.()
  rescue
    error -> {:unreported, Exception.message(error)}
  catch
    kind, reason -> {:unreported, Exception.format_banner(kind, reason)}
  end

  # A token that cannot be written is the SAME operator failure that makes a verdict file
  # unreadable — a full or read-only runs volume — and it happens after the run directory and
  # state.json exist, so the dispatch is already this runner's. As `{:error, _}` it had no wire
  # form and would have left that dispatch in flight for ever, which is the hole this module
  # exists to close; `no_verdict_written` is what the run produced, stated without claiming a
  # session ran.
  defp mint(run_dir, fun) do
    case fun.(run_dir) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:unreported, reason}
    end
  end

  # The checkout is never branched and never the session's cwd: a triage session judges the
  # commit it has out, from a detached worktree (`detached_tree/7`).
  #
  # Its failures are `{:unreadable, _}` rather than `{:error, _}`, because this function LOOKED:
  # the contract has a reason for exactly this and a verified cause is reportable.
  defp checkout(config, repo) do
    name = repo |> String.split("/") |> List.last()

    case Map.fetch(config.repos, name) do
      {:ok, path} ->
        if File.dir?(path),
          do: {:ok, name, path},
          else: {:unreadable, "#{path} is not a directory"}

      :error ->
        {:unreadable, "#{repo} has no local checkout in repos"}
    end
  end

  # 2: the operator's ceilings bind a triage run exactly as `Story` binds an implement one. A
  # dispatch that asks for more is refused rather than quietly granted.
  defp budgets(config, opts) do
    cond do
      wall_clock_s(config, opts) > config.max_wall_clock_s ->
        {:error, "wall clock #{wall_clock_s(config, opts)}s is over this runner's limit"}

      max_turns(config, opts) > config.max_turns ->
        {:error, "#{max_turns(config, opts)} turns is over this runner's limit"}

      true ->
        :ok
    end
  end

  defp wall_clock_s(config, opts),
    do: Keyword.get(opts, :wall_clock_s, min(1800, config.max_wall_clock_s))

  defp max_turns(config, opts), do: Keyword.get(opts, :max_turns, min(60, config.max_turns))

  # The session's tree, in two shapes. The repo's REUSED tree (`Worktree.triage_tree_path/2`)
  # when this run takes its lock: refreshed to the checkout's commit, left in place afterwards,
  # and cheap, because a full checkout per dispatch is not. Its OWN tree
  # (`Worktree.triage_tree_path/3`) when a live run holds that lock, so two runs never share one:
  # cut for this run and removed at its teardown. Both are SCRATCH — detached, so nothing a
  # session writes there is anywhere else — and the entry says so, which is what the reaper reads.
  #
  # Recorded BEFORE it is cut, as an implement run's worktree is, so a BEAM that dies mid-run
  # leaves it where the reaper looks. A checkout git will not read is `checkout_unreadable`; a
  # readable one whose tree could not be cut (a full disk, a path in the way) is the runner's own
  # failure to prepare the run, which the contract reports as `no_verdict_written` (`mint/2`).
  #
  # `cut/2` ends with a tree at the path, with none (`Worktree` removes one it could not finish), or
  # with `{:tree_left, _}` when that removal failed too. `not_prepared` is only ever the entry of a
  # run that has no tree; one that was left is recorded `created`, as the tree it is, and given back
  # exactly as a finished run's is — so the reaper retries a removal that fails here.
  defp detached_tree(config, path, run_dir, run_id, trace, seq, owner) do
    with {:ok, tree} <- prepared(fn -> claim_tree(config, path, run_id, owner) end) do
      result =
        prepared(fn ->
          ScratchRun.record_tree(run_dir, tree, "creating")
          cut(path, tree)
        end)

      case result do
        {:ok, sha} ->
          {:ok, %{tree | base: sha}}

        {:tree_left, reason} ->
          give_back_left(config, tree, run_dir, run_id, trace, seq)
          {:unreported, reason}

        failed ->
          # Truthful, and terminal: nothing of this run's is at that path, so the reaper — which
          # skips this status — must not go and remove what is. Then the lock, or the next run on
          # this repo would find the reused tree held by a run that has ended.
          abandon_tree(config, run_dir, tree, run_id)
          failed
      end
    end
  end

  defp claim_tree(config, path, run_id, owner) do
    shared = Worktree.triage_tree_path(config.runs_dir, path)

    case WorktreeLock.acquire(config.runs_dir, shared, run_id, owner) do
      :ok ->
        {:ok, %{repo_path: path, path: shared, shared?: true, base: "HEAD"}}

      {:error, {:held, _}} ->
        own = Worktree.triage_tree_path(config.runs_dir, path, run_id)
        {:ok, %{repo_path: path, path: own, shared?: false, base: "HEAD"}}
    end
  end

  defp cut(path, %{shared?: true, path: tree}),
    do: tree_result(Worktree.refresh_detached(path, tree))

  defp cut(path, %{shared?: false, path: tree}),
    do: tree_result(Worktree.create_detached(path, tree))

  defp tree_result({:error, reason}), do: {:unreported, reason}
  defp tree_result({:error, reason, :tree_left}), do: {:tree_left, reason}
  defp tree_result(other), do: other

  # The reused tree is released, a run's own given back as `ScratchRun.give_back_left/4` gives it.
  defp give_back_left(config, %{shared?: true} = tree, run_dir, run_id, trace, seq) do
    prepared(fn -> ScratchRun.record_tree(run_dir, tree, "created") end)
    release_tree(config, tree, run_dir, run_id, trace, seq)
  end

  defp give_back_left(config, tree, run_dir, run_id, trace, seq),
    do:
      ScratchRun.give_back_left(
        config,
        tree,
        %{run_dir: run_dir, run_id: run_id, trace: trace, seq: seq},
        "triage"
      )

  defp abandon_tree(config, run_dir, tree, run_id) do
    prepared(fn -> ScratchRun.record_tree(run_dir, tree, "not_prepared") end)
    if tree.shared?, do: WorktreeLock.release(config.runs_dir, tree.path, run_id)
  end

  # The reused tree is RELEASED, not removed: the next run refreshes it, and the reaper skips a
  # released entry because the tree is no longer this run's. A run's own tree is removed whatever
  # it holds — nothing a triage session writes is work to keep, and with no branch there is nowhere
  # for it to have gone — and so is the Claude project directory its unique cwd made.
  # Guarded as `finish/5` is, and for its reason: a run directory the session removed must not
  # turn a finished run into a raise. EVERY way out, exits included — `Trace.emit/4` is a call, and
  # this runs in the `after` that follows `judge/8`, so an exit escaping here would replace the
  # verdict the run already has with an `{:error, _}`, which has no wire form.
  defp release_tree(config, %{shared?: true} = tree, run_dir, run_id, trace, seq) do
    Trace.emit(trace, "worktree.released", seq, %{"worktree" => tree.path})
    ScratchRun.record_tree(run_dir, tree, "released")
  rescue
    error ->
      Logger.error("the triage run's worktree release could not be recorded: #{inspect(error)}")
  catch
    kind, reason ->
      Logger.error(
        "the triage run's worktree release could not be recorded: #{inspect({kind, reason})}"
      )
  after
    WorktreeLock.release(config.runs_dir, tree.path, run_id)
  end

  defp release_tree(config, tree, run_dir, run_id, trace, seq),
    do:
      ScratchRun.release(
        config,
        tree,
        %{run_dir: run_dir, run_id: run_id, trace: trace, seq: seq},
        "triage"
      )

  defp session(config, prompt, {repo_name, path, tree}, run_dir, run_id, trace, seq, opts) do
    session_id = Session.uuid4()
    wall_clock_s = wall_clock_s(config, opts)
    max_turns = max_turns(config, opts)

    argv =
      TriageTools.claude_args(prompt, session_id, TriagePrompt.system_prompt(),
        max_turns: max_turns,
        model: Keyword.get(opts, :model)
      )

    # A Story only to satisfy what Session records about a run; nothing in the argv comes from it,
    # because `:argv` replaces the implement launcher's whole line.
    story = %Story{
      id: run_id,
      repo: repo_name,
      repo_path: path,
      base: "",
      branch: "",
      prompt: prompt,
      wall_clock_s: wall_clock_s,
      max_turns: max_turns,
      # Recorded so the trace says which model judged this report, not only that one ran.
      model: Keyword.get(opts, :model),
      # The same stop bound an implement session has (`Story.stop_after/4`).
      deadline_at: Keyword.get(opts, :deadline_at)
    }

    Session.run(
      config: config,
      story: story,
      worktree: tree,
      run_dir: run_dir,
      trace: trace,
      parent: seq,
      session_id: session_id,
      argv: argv,
      # The repo's own knobs, exactly as an implement run gets them: design §4 has a triage
      # session reading the database, and session_env is where an operator configures that.
      env: Config.session_env_for(config, repo_name, run_id, run_id)
    )
  end

  # What the run produced, judged in the order that tells the truth: a verdict the session wrote
  # is the answer even if the session then failed, because it stated it; only then does how the
  # session ended matter.
  @doc """
  What a run's directory says it concluded, for a run that died before it could say so itself:
  `outcome/2` with no session, so a verdict the session wrote still wins and bytes that are not a
  verdict are still `verdict_invalid`.

  It exists so that the one process left — whoever was supervising the run — does not have to
  make this judgement a second time, in its own words. The mapping from what is on disk to an
  outcome belongs here, with the run, or the two answers drift and the second one to reach loopctl
  is refused permanently.
  """
  @spec outcome_on_disk(String.t()) :: outcome()
  def outcome_on_disk(run_dir), do: outcome(run_dir, nil)

  defp outcome(run_dir, session) do
    case TriageVerdict.read(run_dir) do
      {:ok, verdict} -> {:verdict, note_bare_escalation(verdict)}
      {:error, :none} -> incomplete(run_dir, session)
      {:error, {:invalid, reason}} -> reported("verdict_invalid", reason)
      # An IO failure reaches loopctl as an incomplete rather than a runner error — loopctl asked
      # for that on the argument that decided checkout_unreadable: an error has no wire form, so
      # it leaves the dispatch in flight for ever. WHICH incomplete is decided by looking, not
      # assumed, because the contract defines verdict_invalid as the session having written one.
      {:error, {:unreadable, reason}} -> unreadable(run_dir, reason)
    end
  end

  # Logged and SENT, never refused — `TriageVerdict.bare_escalation?/1` carries the argument. It is
  # said here because this is the one moment the runner holds the verdict and knows it is about to
  # go: the run is over, the session cannot be asked again, and loopctl will record it as it stands.
  # An error rather than a warning, because what reaches the human on the other end of this
  # escalation is a classification and no words, and the prompt that should have got a sentence out
  # of the session is the thing to go and look at.
  defp note_bare_escalation(verdict) do
    if TriageVerdict.bare_escalation?(verdict) do
      Logger.error(
        "this run's escalate verdict carries no words a person can act on: every " <>
          "escalation_reason is one of the bare codes, or there are none. It is being sent as " <>
          "stated — loopctl records the field verbatim and a person receives it — but whoever " <>
          "opens it gets a classification and nothing to read"
      )
    end

    verdict
  end

  # Order matters: the runner's own reasons first, because it KNOWS them, and a parked session's
  # TERM shows up as a non-zero exit that would otherwise read as a crash.
  #
  # First of all, the session monitor dying: whatever it wrote still counts, and outcome/2 has
  # already looked, so reaching here means there was no verdict to keep.
  defp incomplete(_run_dir, {:session_failed, detail}),
    do: reported("session_crashed", "the session could not be supervised: #{detail}")

  # WHICH bound ended it, because the two send a reader to different places: its own wall clock is
  # this runner's budget, the deadline is loopctl's placement, reached while the session ran.
  defp incomplete(_run_dir, %{reason: :wall_clock_exceeded, stop_bound: :deadline}),
    do:
      reported("wall_clock_exceeded", "the session's time ran out at the dispatch's deadline_at")

  defp incomplete(_run_dir, %{reason: :wall_clock_exceeded}),
    do: reported("wall_clock_exceeded", "the session ran out of wall clock")

  # The contract has no turn-budget reason: the session stopped, uncrashed, having written none.
  defp incomplete(_run_dir, %{reason: :max_turns_exceeded}),
    do: reported("no_verdict_written", "the session ran out of turns")

  defp incomplete(_run_dir, %{reason: reason}) when reason in [:parked, :not_group_leader],
    do: reported("no_verdict_written", "the runner stopped the session: #{reason}")

  # An escalation says the session judged it could not work at all — never WHY, since the text is
  # its own. `checkout_unreadable` would be the runner asserting a cause it never checked, and
  # sending whoever reads it to a checkout that is fine.
  defp incomplete(run_dir, %{reason: :escalated}),
    do: reported("no_verdict_written", "the session escalated: #{escalation_text(run_dir)}")

  defp incomplete(_run_dir, %{exit_status: status}) when status != 0,
    do: reported("session_crashed", "the session exited #{status}")

  defp incomplete(_run_dir, _session),
    do: reported("no_verdict_written", "the session ended without stating a verdict")

  # A file that will not read is two different outcomes, and the difference is checkable: a
  # REGULAR FILE at the verdict path is something the session wrote — only `loop-verdict` puts one
  # there, by linking it into place — so the runner could not turn what the session wrote into a
  # verdict, which is verdict_invalid as the contract defines it. Anything else at that path, or
  # nothing, means no verdict was ever written: a directory (which `loop-verdict` cannot create)
  # or a path the runner may no longer stat. Reporting the first for the second would assert a
  # cause nobody verified, which is the objection this module already makes to naming a checkout
  # as the reason a session escalated.
  defp unreadable(run_dir, reason) do
    case File.stat(TriageVerdict.file(run_dir)) do
      {:ok, %File.Stat{type: :regular}} -> reported("verdict_invalid", reason)
      _ -> reported("no_verdict_written", reason)
    end
  end

  # The session's own words, decoded out of the line rather than handed on as JSON.
  defp escalation_text(run_dir) do
    case Run.escalations(run_dir) do
      [_ | _] = reasons -> List.last(reasons)
      [] -> "no reason recorded"
    end
  end

  # The outcome as the MESSAGE that states it, written where it was concluded and before anything
  # is told about it.
  #
  # This is what a run that outlives every Control leaves behind. The outcome reaches Control as a
  # message, and a message reaches nobody when no Control is registered to take it: the run would
  # then have done the work, written the verdict, and left loopctl waiting on the dispatch for the
  # life of the claim. Composing it HERE is also the only way to compose it safely — a sweep that
  # rebuilt one later from `verdict.json` and a status string would be one refactor away from
  # different bytes, and loopctl refuses a second, different verdict for a dispatch permanently.
  #
  # Guarded like everything else on this path, and skipped for a run with no dispatch to answer
  # (`execute/4` called without a binding): there is nobody to report to.
  # A run past its deadline owes no message: nothing is recorded for a restart to resend.
  defp record(_run_dir, _binding, {:deadline_passed, _detail}), do: :ok

  defp record(run_dir, %{"dispatch_id" => _, "claim_epoch" => _} = binding, outcome) do
    case TriageDispatch.verdict_message(binding, outcome) do
      {:ok, payload} ->
        with {:error, reason} <- PendingVerdicts.write(run_dir, payload) do
          Logger.error("the triage run's outcome could not be recorded: #{inspect(reason)}")
        end

      {:error, errors} ->
        Logger.error(
          "the triage run's outcome is not a message anything can send: #{inspect(errors)}"
        )
    end
  rescue
    error -> Logger.error("the triage run's outcome could not be recorded: #{inspect(error)}")
  catch
    kind, reason ->
      Logger.error("the triage run's outcome could not be recorded: #{inspect({kind, reason})}")
  end

  defp record(_run_dir, _binding, _outcome), do: :ok

  defp outcome_name({:deadline_passed, _}), do: "deadline_passed"
  defp outcome_name({:verdict, _}), do: "verdict"
  defp outcome_name({:incomplete, reason, _}), do: "incomplete:#{reason}"
  defp outcome_name({:error, _}), do: "failed"

  defp run_dir(config, record, run_id) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    dir = Path.join(config.runs_dir, "triage-#{record}-#{stamp}-#{binary_part(run_id, 0, 8)}")
    File.mkdir_p!(dir)
    dir
  end
end
