defmodule Loopctl.Delivery.DispatchPayload do
  @moduledoc """
  The fields of a dispatch that loopctl KNOWS, filled in from its own records (#803, #850).

  `RunnerDispatch` requires `repo`, `branch`, `base_branch`, `wall_clock_seconds` and
  `max_turns`, and `cast_dispatch/1` applies no defaults — so a caller that omits one is
  refused. That refusal is expensive and arrives late: `Runners.dispatch/3` casts the payload
  as its FIRST step, which runs after `Placement.place/4` has minted a session dispatch,
  claimed the story and appended `dispatch_created` and `story_stage_claimed` to the immutable
  audit chain. A missing field therefore costs two permanent chain entries, an ephemeral key,
  and a claim taken and released, per attempt.

  Every one of those five is something loopctl can look up:

  - `repo` and `base_branch` are the story's project's intake SOURCE — the row that binds a
    project to a repository, and where an operator sets `main` for a repository that uses it;
  - `branch` is derived from the story, so two stories never share one — behind a prefix the
    TARGET RUNNER declared it accepts (`RunnerJoin.branch_prefixes`, contract 1.14.0), so
    loopctl no longer guesses a name each machine independently decides whether to allow;
  - the budgets are the operator's configured policy, which is where a cost decision belongs.

  So an operator names a story and a runner, and nothing else. `Loopctl.Delivery.DispatchDriver`
  names neither a branch nor a repo for the same reason: an unattended placement goes through
  THIS module rather than through a copy of it, so the branch an operator's dispatch lands on
  and the one the driver would have chosen cannot be two names.

  ## What it will NOT fill in

  A caller's own value wins where loopctl has no better claim to it: a smaller `max_turns` or
  a deliberate `repo` passes through untouched.

  `branch` IS NOW JUDGED rather than merely deferred to (contract 1.14.0, story 846.2), and
  that is the one place this module's own rule bends. A caller's branch is still never
  REWRITTEN — silently renaming the branch an operator asked for would start a session on a
  name nobody chose — but one that violates the target runner's declared prefixes is refused
  here (`{:branch_not_allowed, branch, prefixes}`) instead of being refused by the machine
  after the story has been claimed for it.

  What no caller may supply at all is the `story` object, which `Placement.place/4` refuses
  outright — loopctl builds that from the story row, because a control plane able to hand a
  runner prose is able to run anything on that machine.
  """

  import Ecto.Query

  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Intake
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  @type error ::
          :story_not_found
          | {:no_intake_source, Ecto.UUID.t()}
          | {:ambiguous_intake_source, Ecto.UUID.t(), pos_integer()}
          | {:unset, atom()}
          | {:over_contract_maximum, atom()}
          | {:no_conforming_branch, [String.t()]}
          | {:branch_not_allowed, String.t(), [String.t()]}

  # The prefix loopctl has always derived, and the one it still derives for a runner that
  # declares nothing. NOT changed to `loop/` to fix the machine that started this (story
  # 846.2): that repairs minis and breaks the next box. The control plane stops guessing; it
  # does not guess differently.
  @default_prefix "feature/"

  # A GIT REF NAME, fully anchored, applied to the COMPOSED branch rather than to the prefix.
  # `RunnerJoin.branch_prefixes` already refuses most of this at the wire and says why it is
  # not enough: its `^...$` admits a trailing newline under PCRE, it cannot see `//` spanning
  # a prefix, and a Presence meta can be built without passing that cast at all. This is the
  # check that decides, and it is deliberately narrower than git's own rules — every name it
  # admits is one git accepts, which is the direction that matters.
  @branch_name ~r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}

  # Nothing on the wire can reach this: eight prefixes of 40 characters and a suffix under 30
  # leave it unreachable by a factor of two. It is the bound that holds when the prefixes came
  # from somewhere other than `cast_join/1`, the same role `Runners.declared_max_sessions/1`'s
  # clamp plays for capacity.
  @max_branch_length 120

  @doc """
  Fills the dispatch fields `dispatch` does not carry, from the story's own records.

  Returns the payload with string keys, ready for `Placement.place/4`. `{:error, reason}` when
  a field cannot be derived and the caller did not supply it — a project bound to no intake
  source, or a budget the operator has not set — which is a refusal BEFORE anything is minted
  rather than after.

  `kind` decides which budgets are read: an `implement` session and a `triage` session are
  different pieces of work with different costs, and the operator sets them separately.

  ## Options

  - `:branch_prefixes` — what the TARGET RUNNER declared it accepts
    (`RunnerJoin.branch_prefixes`, contract 1.14.0), read live off its Presence meta by
    `Loopctl.Delivery.Placement`. `[]` — which is what every runner built before 1.14.0
    yields — is no constraint and derives exactly the branch this module derived before the
    field existed.
  """
  @spec fill(Ecto.UUID.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def fill(tenant_id, %{} = dispatch, opts \\ []) when is_binary(tenant_id) and is_list(opts) do
    story_id = Map.get(dispatch, "story_id")
    kind = Map.get(dispatch, "kind", "implement")
    prefixes = Keyword.get(opts, :branch_prefixes, [])

    with {:ok, story} <- fetch_story(tenant_id, story_id),
         {:ok, dispatch} <- fill_repo(tenant_id, story, dispatch),
         {:ok, dispatch} <- fill_budgets(kind, dispatch) do
      fill_branch(dispatch, story, prefixes)
    end
  end

  @doc """
  The branch a story's session works on: its number, and eight characters of its id, behind a
  prefix the target runner accepts.

  The id is in it because a story NUMBER is unique only within its project, and two projects
  may hold intake sources naming the same repository — nothing forbids it. Without the suffix
  two different stories dispatched to one repository could be given one branch, and the second
  session would find the first's work already there.

  ## Why `prefixes` is an argument and not a constant

  The prefix used to be hard-coded `feature/`, and each runner's own config carries the
  prefixes it accepts, and NOTHING RECONCILED THEM: the delivery loop's first real placement
  was refused `branch_not_allowed` because minis accepted `loop/` alone, the story was parked,
  and an operator could discover the required prefix only by reading a config file on that
  machine. That is the shape `kinds` had before contract 1.6.0 — a per-machine capability the
  control plane had to guess — and it has the same fix: the runner DECLARES
  (`RunnerJoin.branch_prefixes`), loopctl DERIVES.

  `[]` is no constraint and yields the `feature/` name this function has always produced, so
  a runner that declares nothing is placed on exactly as it was. Otherwise the FIRST prefix
  that produces a valid branch name wins — the declaration is in the machine's own preference
  order, and taking the first is what makes a retry of one story produce one name rather than
  a different one per attempt.

  ## When it refuses

  `{:error, {:no_conforming_branch, prefixes}}` when no declared prefix can produce a valid
  branch name — a prefix carrying `//`, one that would push the name past
  `#{@max_branch_length}` characters, one that survived the wire with a trailing newline.

  The suffix is NEVER shortened to make one fit. It is what keeps two stories on one
  repository off one branch, so a prefix that leaves no room for it is a refusal and not a
  truncation. It refuses the PLACEMENT and not the join, following the same trade
  `Loopctl.Runners.declared_max_sessions/1` documents: a machine that cannot get a socket is
  out of the fleet entirely, which is a far worse outcome than one story that cannot be
  placed on it.
  """
  @spec branch_for(Story.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, {:no_conforming_branch, [String.t()]}}
  def branch_for(%Story{} = story, prefixes \\ []) when is_list(prefixes) do
    suffix = "story-#{story.number}-#{String.slice(story.id, 0, 8)}"

    usable = for p <- prefixes, is_binary(p), do: p
    candidates = if usable == [], do: [@default_prefix], else: usable

    case Enum.find(candidates, &valid_branch?(&1 <> suffix)) do
      nil -> {:error, {:no_conforming_branch, prefixes}}
      prefix -> {:ok, prefix <> suffix}
    end
  end

  @doc """
  Whether `branch` satisfies what the runner declared — the check for a branch the CALLER
  supplied, where there is nothing to derive.

  An operator naming a branch by hand hits the same wall the derivation was fixed for, and on
  the placement path it costs more: the runner's `branch_not_allowed` arrives after the story
  has been claimed for it. So `Loopctl.Delivery.Placement` asks this before the claim. `[]`
  allows everything, which is both the pre-1.14.0 behaviour and the right answer for a
  machine that has declared no constraint.
  """
  @spec branch_allowed?(String.t(), [String.t()]) :: boolean()
  def branch_allowed?(branch, prefixes) when is_binary(branch) and is_list(prefixes) do
    case for p <- prefixes, is_binary(p), do: p do
      [] -> true
      usable -> Enum.any?(usable, &String.starts_with?(branch, &1))
    end
  end

  # Narrower than git's own rules on purpose: everything admitted here is a name git accepts.
  # `//` and a trailing `/` are what a prefix can introduce that no per-entry pattern sees,
  # and `..`/`.lock` are refused because a prefix may not carry `.` at all on the wire — this
  # re-checks them anyway, since a meta can reach here without passing `cast_join/1`.
  defp valid_branch?(branch) do
    Regex.match?(@branch_name, branch) and
      byte_size(branch) <= @max_branch_length and
      not String.contains?(branch, ["//", ".."]) and
      not String.ends_with?(branch, ["/", ".", ".lock"])
  end

  # A CALLER'S OWN BRANCH IS NEVER REWRITTEN, only judged. Every other field here follows the
  # module's rule that a caller's value wins, and a control plane that silently renamed the
  # branch an operator asked for would be worse than one that refuses: the session would run,
  # on a name nobody named, and the operator would go looking for work on the other one.
  defp fill_branch(dispatch, story, prefixes) do
    case Map.fetch(dispatch, "branch") do
      {:ok, branch} when is_binary(branch) ->
        if branch_allowed?(branch, prefixes),
          do: {:ok, dispatch},
          else: {:error, {:branch_not_allowed, branch, prefixes}}

      {:ok, _not_a_string} ->
        # Left to `cast_dispatch/1`, which is the one declaration of what the wire accepts.
        {:ok, dispatch}

      :error ->
        with {:ok, branch} <- branch_for(story, prefixes),
             do: {:ok, Map.put(dispatch, "branch", branch)}
    end
  end

  defp fill_repo(tenant_id, story, dispatch) do
    if Map.has_key?(dispatch, "repo") and Map.has_key?(dispatch, "base_branch") do
      {:ok, dispatch}
    else
      with {:ok, source} <- Intake.source_for_project(tenant_id, story.project_id) do
        {:ok,
         dispatch
         |> put_new("repo", source.repo_full_name)
         |> put_new("base_branch", source.base_branch)}
      end
    end
  end

  # ONE READ OF THE OPERATOR'S POLICY, and the same reader the unattended driver uses, so an
  # operator's placement and the driver's cannot disagree about what a session may spend.
  defp fill_budgets(kind, dispatch) do
    if Map.has_key?(dispatch, "wall_clock_seconds") and Map.has_key?(dispatch, "max_turns") do
      {:ok, dispatch}
    else
      {clock_key, turns_key} = budget_keys(kind)

      with {:ok, seconds} <- budget(clock_key),
           {:ok, turns} <- budget(turns_key) do
        {:ok,
         dispatch
         |> put_new("wall_clock_seconds", seconds)
         |> put_new("max_turns", turns)}
      end
    end
  end

  defp budget_keys("triage"), do: {:triage_wall_clock_seconds, :triage_max_turns}
  defp budget_keys(_implement), do: {:dispatch_wall_clock_seconds, :dispatch_max_turns}

  defp budget(key), do: DispatchDriver.normalise_budget(Application.get_env(:loopctl, key), key)

  defp fetch_story(tenant_id, story_id) when is_binary(story_id) do
    {:ok, story} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.one(from s in Story, where: s.id == ^story_id and s.tenant_id == ^tenant_id)
      end)

    if story, do: {:ok, story}, else: {:error, :story_not_found}
  end

  defp fetch_story(_tenant_id, _story_id), do: {:error, :story_not_found}

  defp put_new(dispatch, key, value) do
    if Map.has_key?(dispatch, key), do: dispatch, else: Map.put(dispatch, key, value)
  end
end
