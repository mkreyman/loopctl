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
    2. `draining`, then `at_capacity` (in flight at `control.max_sessions`);
    3. `repo_not_allowed` — the repo is not in `control.repos`, or has no local checkout in
       `repos` under its name;
    4. `insufficient_disk` — free disk under `control.min_free_disk_mb`, or unreadable, on the
       volume of `runs_dir` OR of the repo checkout, where the worktree and its build output land;
    5. `branch_not_allowed` — the branch is outside `branch_prefixes`, or either ref is not a
       plain ref name;
    6. `wall_clock_exceeds_limit`, `max_turns_exceeds_limit` — over `max_wall_clock_s` or
       `max_turns`;
    7. `token_budget_exceeds_limit` — when `control.max_token_budget` is set, a dispatch with no
       budget or a larger one.

  An accepted dispatch comes back as the fields a `LoopctlRunner.Story` is built from.
  """

  alias LoopctlRunner.{Config, ControlConfig}

  @ref_format ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/

  @type state :: %{
          :draining => boolean(),
          :in_flight => non_neg_integer(),
          # Free MB on the volume holding a path, nil when unreadable.
          :free_disk_mb => (String.t() -> non_neg_integer() | nil),
          # What to say instead of the configured-false sentence, when something other than the
          # config turned dispatches off for this process.
          optional(:dispatches_disabled_detail) => String.t() | nil
        }

  @type decision ::
          {:accept, map()} | {:refuse, String.t(), String.t()}

  @spec decide(map(), Config.t(), state()) :: decision()
  def decide(dispatch, %Config{control: %ControlConfig{} = control} = config, state) do
    with :ok <- enabled(control, state),
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
         :ok <- token_budget(dispatch["token_budget"], control.max_token_budget) do
      {:accept,
       %{
         repo: repo,
         repo_path: path,
         base: dispatch["base_branch"],
         branch: dispatch["branch"],
         wall_clock_s: dispatch["wall_clock_seconds"],
         max_turns: dispatch["max_turns"]
       }}
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

  defp refs(%{"base_branch" => base, "branch" => branch}, config)
       when is_binary(base) and is_binary(branch) do
    cond do
      not plain_ref?(base) or not plain_ref?(branch) ->
        {:refuse, "branch_not_allowed", "a ref is not a plain ref name"}

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
end
