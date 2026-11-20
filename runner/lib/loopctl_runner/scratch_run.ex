defmodule LoopctlRunner.ScratchRun do
  @moduledoc """
  What a run on a SCRATCH tree needs — a triage run (`LoopctlRunner.TriageRun`): a detached
  worktree under the runner's `runs_dir`, recorded `scratch` in `state.json` before it is cut,
  so the reaper removes it whatever it holds, and removed at the run's teardown with the Claude
  project directory its unique cwd made.

  `kind` is the run's kind as its log lines name it ("triage").
  """

  require Logger

  alias LoopctlRunner.{Config, Reaper, RunState, Trace, Uuid, Worktree}

  @typedoc "A scratch tree: the checkout it was cut from, its path, and the commit it was cut at."
  @type tree :: %{
          required(:repo_path) => String.t(),
          required(:path) => String.t(),
          required(:base) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "Where a run reports its teardown: its directory, id, trace and the trace's parent seq."
  @type where :: %{
          required(:run_dir) => String.t(),
          required(:run_id) => String.t(),
          required(:trace) => pid(),
          required(:seq) => term(),
          optional(atom()) => term()
        }

  @doc """
  What an implement run does before it starts (`LoopctlRunner.Run`), for the same reason: a
  scratch run may be the only kind this runner is sent for a while, and an orphaned scratch tree
  — or a lock on the reused triage tree, which the next run on the repo would find held — would
  otherwise wait for an implement dispatch. Guarded: a reap that fails costs this run nothing.
  """
  @spec reap(Config.t(), map(), String.t()) :: term()
  def reap(config, owner, kind) do
    Reaper.reap(config.runs_dir, config.kill_grace_s * 1000, config.grant_dir,
      projects_dir: config.claude_projects_dir,
      owner: {:ok, owner}
    )
  rescue
    error -> Logger.error("the reap before a #{kind} run failed: #{inspect(error)}")
  catch
    kind_, reason ->
      Logger.error("the reap before a #{kind} run failed: #{inspect({kind_, reason})}")
  end

  @doc """
  Records `tree` in the run's state with `status`, as the scratch tree it is: on no branch, and
  `scratch`, which is what makes the reaper remove it whatever it holds.
  """
  @spec record_tree(String.t(), tree(), String.t()) :: map()
  def record_tree(run_dir, tree, status) do
    RunState.update(run_dir, %{
      "repo_path" => tree.repo_path,
      "worktree" => %{
        "path" => tree.path,
        "branch" => "",
        "base" => tree.base,
        "status" => status,
        "scratch" => true,
        # A triage repo's one reused tree outlives every run: Control never gives it to the reaper
        # when its run is killed (`give_scratch_tree_to_reaper`); the reaper still removes it for a
        # run whose BEAM died, which cannot free it any other way.
        "reused" => Map.get(tree, :shared?, false)
      }
    })
  end

  @doc """
  Removes a run's own scratch tree whatever it holds — nothing a scratch session writes is work to
  keep, and with no branch there is nowhere for it to have gone — and the Claude project directory
  its unique cwd made.

  Guarded, EVERY way out, exits included: `Trace.emit/4` is a call, and this runs in the `after`
  that follows the session, so an exit escaping here would replace the run's finished result with
  a crash.
  """
  @spec release(Config.t(), tree(), where(), String.t()) :: term()
  def release(config, tree, where, kind) do
    outcome = Worktree.remove(tree.repo_path, tree.path, "", tree.base)
    status = Worktree.status_after(outcome)

    Trace.emit(where.trace, "worktree.#{status}", where.seq, %{
      "worktree" => inspect(outcome.worktree)
    })

    record_tree(where.run_dir, tree, status)
  rescue
    error ->
      Logger.error("the #{kind} run's worktree removal could not be recorded: #{inspect(error)}")
  catch
    kind_, reason ->
      Logger.error(
        "the #{kind} run's worktree removal could not be recorded: #{inspect({kind_, reason})}"
      )
  after
    remove_project_dir(config.claude_projects_dir, where.run_id)
  end

  @doc """
  A tree whose cut failed and whose removal failed too (`{:error, _, :tree_left}` from
  `LoopctlRunner.Worktree`) is still a tree: recorded `created`, as the tree it is, and released
  exactly as a finished run's is — so the reaper retries a removal that fails here.
  """
  @spec give_back_left(Config.t(), tree(), where(), String.t()) :: term()
  def give_back_left(config, tree, where, kind) do
    guarded(fn -> record_tree(where.run_dir, tree, "created") end)
    release(config, tree, where, kind)
  end

  defp guarded(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  @doc """
  Brings the submodules of a run's scratch tree to the commits it records, and returns the paths
  that could not be — which go to the trace and the state as well as the session's prompt
  (`missing_note/2`), so a judgement made without them can be told apart from one that had them.
  """
  @spec submodules(tree(), where()) :: [String.t()]
  def submodules(tree, where) do
    case Worktree.sync_submodules(tree.repo_path, tree.path) do
      :ok ->
        []

      {:missing, paths, detail} ->
        Trace.emit(where.trace, "worktree.submodules_missing", where.seq, %{
          "paths" => paths,
          "detail" => detail
        })

        RunState.update(where.run_dir, %{"submodules_missing" => paths})
        paths
    end
  end

  @doc """
  What a scratch session is told when `submodules/2` could not initialise `paths` — nothing when
  it could — so an empty directory where a submodule should be is read as the runner's failure.
  `instead` is the rest of the sentence, which is the kind's: what the session does about it.
  Each path is QUOTED: they come from the repository's own `.gitmodules`, which is text anyone
  who can commit there wrote.
  """
  @spec missing_note([String.t()], String.t()) :: String.t()
  def missing_note([], _instead), do: ""

  def missing_note(paths, instead) do
    "\nThe runner could NOT initialise this checkout's submodules, so these paths may be empty " <>
      "or at the wrong commit: #{Enum.map_join(paths, ", ", &inspect/1)}. What is missing under " <>
      "them is the runner's failure, #{instead}\n"
  end

  @doc """
  Removes the Claude project directory a scratch run's OWN tree made, so the reaper can do for an
  orphan what the run's teardown does for itself.

  Claude Code keeps one project directory per cwd, and a run's own tree is a cwd no other run
  will have, so each would leave one behind for ever. Found by the run id its path carries rather
  than by re-deriving the CLI's path-mangling rule, for `Liveness.file_signals/2`'s reason: that
  rule is not a documented contract. Only for a uuid, which carries no glob metacharacter — an
  id that did would widen the match to directories that are not this run's. The reused triage
  tree's path carries no run id, so its one directory is never matched.
  """
  @spec remove_project_dir(String.t(), term()) :: :ok
  def remove_project_dir(projects_dir, run_id) do
    if Uuid.valid?(run_id) do
      projects_dir
      |> Path.join("*" <> run_id <> "*")
      |> Path.wildcard()
      |> Enum.each(&File.rm_rf/1)
    end

    :ok
  rescue
    error ->
      Logger.error("a scratch run's project directory was not removed: #{inspect(error)}")
      :ok
  end
end
