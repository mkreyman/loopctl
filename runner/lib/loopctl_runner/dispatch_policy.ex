defmodule LoopctlRunner.DispatchPolicy do
  @moduledoc """
  Whether this runner takes a dispatch (design §7): the local allow-list every dispatch is
  checked against, refusing by default.

  A dispatch is an arbitrary prompt executed as this machine's user with its credentials, so
  loopctl's own checks are not enough: the runner decides from its own configuration. The
  first failing check names the refusal, as `RunnerDispatchReply.reason`:

    1. `dispatches_disabled` — `control.accepts_dispatches` is not true (the default). The
       `detail` says WHICH `dispatches_disabled` this is: the reason is one value for two
       conditions — a machine configured not to take work, and a foreground `mix loopctl.serve`
       run refusing by default — and from loopctl's side they are otherwise indistinguishable, so
       a reader guesses which machine is misconfigured. The caller supplies the alternative
       wording through `:dispatches_disabled_detail` in `state`; absent, the configured case's own
       sentence is used. Never an empty string: a detail that says nothing is worse than the
       default one, because loopctl would have to special-case it;
    2. `other`, its detail starting `busy:` — `state.ending`: a run of this same dispatch started
       no session and is still ending (`LoopctlRunner.Control` forgets such a dispatch the moment
       its end is reported, so a re-send reaches this decision while that run's task is still in
       flight). A moment, like the deadline's refusal below, never a capability; loopctl places the
       story again;
    3. `draining`, then `at_capacity` (in flight at `control.max_sessions`);
    4. `repo_not_allowed` — the repo is not in `control.repos`, or has no local checkout in
       `repos` under its name;
    5. `insufficient_disk` — free disk under `control.min_free_disk_mb`, or unreadable, on the
       volume of `runs_dir` OR of the repo checkout, where the worktree and its build output land;
    6. `branch_not_allowed` — the branch is outside `branch_prefixes`, or either ref is not a
       plain ref name. A `review` dispatch is held to the second half only: its `branch` is the
       IMPLEMENTER's, derived from whatever prefixes that machine declared, and a review never
       cuts, writes or pushes it — it only fetches it, which a plain ref name is what makes safe.
       Refusing one for a prefix this machine enforces on the branches it WRITES would turn away
       every review of a story implemented elsewhere. A `triage` dispatch is held to the second
       half too: it names the base branch as its `branch` and runs on a detached tree that is
       never branched or pushed, so a prefix check refused every one (minis, 2026-11-06);
    7. `wall_clock_exceeds_limit`, `max_turns_exceeds_limit` — over `max_wall_clock_s` or
       `max_turns`;
    8. `token_budget_exceeds_limit` — when `control.max_token_budget` is set, a dispatch with no
       budget or a larger one;
    9. `other`, its detail starting `deadline_passed:` — the dispatch's `deadline_at` (contract
       1.19.0) leaves less than the minimum runtime (`min_session_s`, capped by the dispatch's
       `wall_clock_seconds`) of session before it must be stopped
       (`LoopctlRunner.Story.check_deadline/4`). A statement about a moment, never a capability:
       the contract has no reason of its own for it, and `kind_not_supported` would be a lie that
       loopctl may keep for ever. loopctl places the story again under a fresh claim.

  An accepted dispatch comes back as the fields a `LoopctlRunner.Story` is built from, its
  `deadline_at` parsed once, here, into the instant everything after reads.

  `state` may carry `:now`, the instant the deadline is judged at; absent, it is the current time.

  The refusals that read what the dispatch does not carry are decided once the run has cut its
  worktree: `delivery_mode/1` (the repository's `.loopctl/mode`, read from the commit the worktree
  was cut from), and for a `thread` session `push_helper/2` (its only way to push) and
  `checkpoint_reporting/2` (how loopctl learns what it pushed). Each refuses `other`, and each
  fails closed: a run it refuses starts no session.
  """

  alias LoopctlRunner.{Config, ControlConfig, Story}

  @ref_format ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/

  @type state :: %{
          :draining => boolean(),
          :in_flight => non_neg_integer(),
          # Free MB on the volume holding a path, nil when unreadable.
          :free_disk_mb => (String.t() -> non_neg_integer() | nil),
          # What to say instead of the configured-false sentence, when something other than the
          # config turned dispatches off for this process.
          optional(:dispatches_disabled_detail) => String.t() | nil,
          # Whether a run of this dispatch that started no session is still ending.
          optional(:ending) => boolean(),
          optional(:now) => DateTime.t()
        }

  @type decision ::
          {:accept, map()} | {:refuse, String.t(), String.t()}

  @spec decide(map(), Config.t(), state()) :: decision()
  def decide(dispatch, %Config{control: %ControlConfig{} = control} = config, state) do
    with :ok <- enabled(control, state),
         :ok <- ending(state),
         :ok <- capacity(control, state),
         {:ok, repo, path} <- repo(dispatch, control, config),
         :ok <- disk(control, state, [config.runs_dir, path]),
         :ok <- refs(dispatch, config),
         :ok <-
           limit(
             dispatch["wall_clock_seconds"],
             config.max_wall_clock_s,
             "wall_clock_exceeds_limit"
           ),
         :ok <- limit(dispatch["max_turns"], config.max_turns, "max_turns_exceeds_limit"),
         :ok <- token_budget(dispatch["token_budget"], control.max_token_budget),
         deadline_at = Story.deadline!(dispatch["deadline_at"]),
         :ok <- deadline(deadline_at, dispatch["wall_clock_seconds"], config, state) do
      {:accept,
       %{
         repo: repo,
         repo_path: path,
         base: dispatch["base_branch"],
         branch: dispatch["branch"],
         wall_clock_s: dispatch["wall_clock_seconds"],
         max_turns: dispatch["max_turns"],
         deadline_at: deadline_at
       }}
    end
  end

  defp deadline(deadline_at, wall_clock_s, config, state) do
    now = Map.get_lazy(state, :now, &DateTime.utc_now/0)

    case Story.check_deadline(deadline_at, wall_clock_s, config, now) do
      :ok -> :ok
      {:passed, detail} -> {:refuse, "other", detail}
    end
  end

  @configured_off "this runner is not configured to accept dispatches"

  defp enabled(%ControlConfig{accepts_dispatches: true}, _state), do: :ok

  defp enabled(_control, state) do
    case Map.get(state, :dispatches_disabled_detail) do
      detail when is_binary(detail) and detail != "" -> {:refuse, "dispatches_disabled", detail}
      _absent_or_empty -> {:refuse, "dispatches_disabled", @configured_off}
    end
  end

  defp ending(%{ending: true}),
    do: {:refuse, "other", "busy: the previous run of this dispatch is ending; send it again"}

  defp ending(_state), do: :ok

  defp capacity(_control, %{draining: true}), do: {:refuse, "draining", "this runner is draining"}

  defp capacity(%ControlConfig{max_sessions: max}, %{in_flight: in_flight}) when in_flight >= max,
    do: {:refuse, "at_capacity", "#{in_flight} of #{max} sessions in flight"}

  defp capacity(_control, _state), do: :ok

  # Every volume the run writes to must have room; an unreadable figure is a refusal too: it is
  # the precondition, not a preference.
  defp disk(%ControlConfig{min_free_disk_mb: min}, %{free_disk_mb: free_disk_mb}, paths) do
    Enum.find_value(paths, :ok, fn path ->
      case free_disk_mb.(path) do
        free when is_integer(free) and free >= min ->
          nil

        free ->
          {:refuse, "insufficient_disk",
           "free disk #{inspect(free)} MB under #{path}, #{min} MB required"}
      end
    end)
  end

  # The dispatch names owner/name; the local checkout is keyed by name in `repos`.
  defp repo(%{"repo" => repo}, control, config) when is_binary(repo) do
    name = repo |> String.split("/") |> List.last()

    case {repo in control.repos, Map.fetch(config.repos, name)} do
      {true, {:ok, path}} -> {:ok, name, path}
      {false, _} -> {:refuse, "repo_not_allowed", "#{repo} is not in control.repos"}
      {true, :error} -> {:refuse, "repo_not_allowed", "#{repo} has no local checkout in repos"}
    end
  end

  defp repo(_dispatch, _control, _config),
    do: {:refuse, "repo_not_allowed", "the dispatch names no repo"}

  # The kinds that never write their `branch`, so this machine's prefixes, which bound the
  # branches it CUTS and PUSHES, have nothing to bound. A review fetches the implementer's
  # branch; a triage run judges the base from a detached worktree and loopctl names the base
  # itself as `branch` (`LoopctlRunner.TriageRun`). Both keep the plain-ref check above.
  @prefix_exempt_kinds ["review", "triage"]

  defp refs(%{"base_branch" => base, "branch" => branch} = dispatch, config)
       when is_binary(base) and is_binary(branch) do
    cond do
      not plain_ref?(base) or not plain_ref?(branch) ->
        {:refuse, "branch_not_allowed", "a ref is not a plain ref name"}

      dispatch["kind"] in @prefix_exempt_kinds ->
        :ok

      not Enum.any?(config.branch_prefixes, &String.starts_with?(branch, &1)) ->
        {:refuse, "branch_not_allowed", "#{branch} is outside #{inspect(config.branch_prefixes)}"}

      true ->
        :ok
    end
  end

  defp refs(_dispatch, _config),
    do: {:refuse, "branch_not_allowed", "the dispatch names no branch"}

  defp plain_ref?(ref), do: ref =~ @ref_format and not String.contains?(ref, "..")

  defp limit(value, max, _reason) when is_integer(value) and value >= 1 and value <= max, do: :ok

  defp limit(value, max, reason),
    do: {:refuse, reason, "#{inspect(value)} is over this runner's limit of #{max}"}

  defp token_budget(_budget, nil), do: :ok
  defp token_budget(budget, max) when is_integer(budget) and budget <= max, do: :ok

  defp token_budget(budget, max),
    do:
      {:refuse, "token_budget_exceeds_limit",
       "token budget #{inspect(budget)} against this runner's limit of #{max}"}

  @doc """
  The delivery mode stated by a repository's `.loopctl/mode`, given what
  `LoopctlRunner.Worktree.commit_file/4` read from the commit the worktree was cut from: a
  byte-order mark stripped, then whitespace trimmed and case folded, and it must then say
  `thread` or `pr`. Everything else refuses the dispatch `other` — no file (`repository has no
  .loopctl/mode`), an empty one, another word, text that is not UTF-8, a file that could not be
  read — because a mode decides whether the session opens and merges a pull request, and a
  repository that never opted in has not asked for that.
  """
  @spec delivery_mode({:ok, binary()} | :absent | {:error, String.t()}) ::
          {:ok, String.t()} | {:refuse, String.t(), String.t()}
  def delivery_mode(:absent), do: {:refuse, "other", "repository has no .loopctl/mode"}

  def delivery_mode({:error, why}),
    do: {:refuse, "other", "the delivery mode in .loopctl/mode could not be read: " <> why}

  def delivery_mode({:ok, raw}) do
    stated = raw |> String.replace_prefix("\uFEFF", "") |> String.trim()

    cond do
      not String.valid?(stated) ->
        {:refuse, "other", "malformed delivery mode in .loopctl/mode: not UTF-8 text"}

      String.downcase(stated) in ["thread", "pr"] ->
        {:ok, String.downcase(stated)}

      true ->
        {:refuse, "other",
         "malformed delivery mode #{inspect(String.slice(stated, 0, 40))} in .loopctl/mode: " <>
           "expected thread or pr"}
    end
  end

  @doc """
  Whether a session in `mode` has what it needs to finish: a `thread` session pushes ONLY through
  `push_script` (`LoopctlRunner.Session.push_script/0`), so a release without that executable is
  refused `other` rather than started on a prompt naming a command that does not exist.
  """
  @spec push_helper(String.t(), String.t()) :: :ok | {:refuse, String.t(), String.t()}
  def push_helper("thread", push_script) do
    case File.stat(push_script) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o100) != 0 ->
        :ok

      _ ->
        {:refuse, "other",
         "push helper missing: #{push_script} is not an executable file in this release"}
    end
  end

  def push_helper(_mode, _push_script), do: :ok

  @doc """
  Whether a `thread` session's pushes can reach loopctl: its merge executor merges only the
  checkpoints the runner reports, so a thread session on a build with no checkpoint reporter
  (`reporter`, `LoopctlRunner.CheckpointStream` in production) would push work
  nothing ever merges. Such a run is refused `other`; a `pr` session reports nothing and needs
  none.
  """
  @spec checkpoint_reporting(String.t(), module()) :: :ok | {:refuse, String.t(), String.t()}
  def checkpoint_reporting("thread", reporter) do
    if Code.ensure_loaded?(reporter),
      do: :ok,
      else: {:refuse, "other", "checkpoint reporting not available"}
  end

  def checkpoint_reporting(_mode, _reporter), do: :ok
end
