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

  alias Loopctl.ApiSpec.RunnerContract.RunnerDispatch
  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Delivery.Stages
  alias Loopctl.GitRef
  alias Loopctl.Intake
  alias Loopctl.Repo
  alias Loopctl.Runners.Capacity
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.WorkBreakdown.Story

  @type error ::
          :story_not_found
          | {:no_intake_source, Ecto.UUID.t()}
          | {:ambiguous_intake_source, Ecto.UUID.t(), pos_integer()}
          | {:unset, atom()}
          | {:over_contract_maximum, atom()}
          | {:no_conforming_branch, [String.t()]}
          | {:branch_not_allowed, String.t(), [String.t()]}
          | {:invalid_branch_name, atom(), term()}
          | {:branch_not_unique, atom(), String.t(), String.t()}

  # The prefix loopctl has always derived, and the one it still derives for a runner that
  # declares nothing. NOT changed to `loop/` to fix the machine that started this (story
  # 846.2): that repairs minis and breaks the next box. The control plane stops guessing; it
  # does not guess differently.
  @default_prefix "feature/"

  # Where `fill/3` puts the merge mode an implement dispatch is placed under (US-45.4). An ATOM
  # key: it never goes on the wire (`RunnerContract.cast_dispatch/1` keeps only declared
  # fields), and no caller's JSON can supply it.
  @placed_mode :placed_mode

  @doc """
  The key under which `fill/3` carries the intake source's mode, as a string (`"pr"`,
  `"thread"`), or nil for a project with no single live source, to
  `Loopctl.Runners.dispatch/3`, which records it on the ledger row
  (`Loopctl.Runners.DispatchLedger.record_sent/4`), which keeps it on an implement row only.
  """
  @spec placed_mode_key() :: :placed_mode
  def placed_mode_key, do: @placed_mode

  # Nothing on the wire can reach this: eight prefixes of 40 characters and a suffix under 30
  # leave it unreachable by a factor of two. It is the bound that holds when the prefixes came
  # from somewhere other than `cast_join/1`, the same role `Runners.declared_max_sessions/1`'s
  # clamp plays for capacity.
  #
  # IT BOUNDS THE DERIVATION ONLY. A branch a CALLER named is judged against the contract's own
  # bound on the field instead (`RunnerDispatch.max_branch_length/0`, read at the call rather
  # than copied, so the two cannot drift): 120 is headroom this module chose for names it
  # composes itself, and refusing a caller's 130-character branch here would refuse a name the
  # PUBLISHED contract accepts — a refusal no reader of the contract could account for.
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

  - `:prefix_policy` — what a declaration this dispatch cannot satisfy DOES. `:refuse`, the
    default, answers `{:branch_not_allowed, _, _}` or `{:no_conforming_branch, _}`. `:advise`
    uses the declaration wherever it can and falls back to the unconstrained derivation where
    it cannot, refusing for no prefix reason at all. `Loopctl.Delivery.Placement` passes
    `:advise` on the RESUME path and nowhere else — a resume is re-pushing a claim that is
    already STANDING, so a refusal there strands a live claim rather than preventing one; the
    argument is written out in full above `resume_payload/4`.

    IT DOES NOT RELAX `validate_refs/2`, and the split is the point: a prefix is a fact about
    another machine, and everything `validate_refs/2` judges is a fact about the values in
    this request. See `valid_ref_name?/1`.
  """
  @spec fill(Ecto.UUID.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def fill(tenant_id, %{} = dispatch, opts \\ []) when is_binary(tenant_id) and is_list(opts) do
    story_id = Map.get(dispatch, "story_id")
    kind = Map.get(dispatch, "kind", "implement")
    prefixes = Keyword.get(opts, :branch_prefixes, [])
    policy = Keyword.get(opts, :prefix_policy, :refuse)

    with {:ok, story} <- fetch_story(tenant_id, story_id),
         :ok <- validate_refs(dispatch, story),
         {:ok, dispatch} <- fill_repo(tenant_id, story, dispatch),
         {:ok, dispatch} <- fill_budgets(kind, dispatch),
         {:ok, dispatch} <- fill_branch(dispatch, story, prefixes, policy),
         :ok <- validate_refs(dispatch, story) do
      {:ok, dispatch}
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
    suffix = story_suffix(story)

    usable = for p <- prefixes, is_binary(p), do: p
    candidates = if usable == [], do: [@default_prefix], else: usable

    case Enum.find(candidates, &valid_branch?(&1 <> suffix)) do
      nil -> {:error, {:no_conforming_branch, prefixes}}
      prefix -> {:ok, prefix <> suffix}
    end
  end

  @doc """
  The ROUTE `story`'s current claim was bound to (US-45.4, US-45.9): the merge `mode` and the
  `base_branch` it was placed or claimed under, and the branch it named. Read from the route
  rows of the story's CURRENT `claim_epoch` (`Loopctl.Runners.DispatchLedger.claim_route_query/2`,
  which owns those rules): the implement row its runner ACCEPTED, newest first, for a placed
  claim, and the `Loopctl.Delivery.ClaimRoute` an INTERACTIVE claim recorded, both through
  `DispatchLedger.route_rows_query/0`. An interactive claim therefore HAS a route, and never
  inherits the source's live mode or base branch.

  Every field is a RECORDED fact, never a derivation; a caller that needs a fallback applies
  it, and one that does not need a field never pays for resolving it:

  - `mode` — the row's recorded mode (`Loopctl.Runners.DispatchLedger.record_sent/4` binds it
    at placement). A row that records none is `:pr`: written before the column existed, when
    `pr` was the only route, or placed where no single source resolved one. `nil` when there is
    NO route row for the claim (neither an accepted placement nor an interactive claim's
    route, e.g. a claim made before either was recorded); only then does the caller fall back
    to the intake source's CURRENT mode, as it does for the base branch
  - `base_branch` — the base branch the dispatch was placed on, pinned the same way. nil for a
    row that records none (or no route row); only then does the caller fall back to the intake
    source's CURRENT base branch
  - `branch` — the name the dispatch put on the wire (#846.2), or nil. `thread_branch/3`
    resolves the branch a thread is judged on from it

  The read's lock wait is bounded (`Loopctl.Runners.Capacity.set_lock_timeout!/1`).
  `{:error, :busy}` for contention a caller retries out of
  (`Loopctl.Delivery.Stages.answering_busy/4`, counted as
  `[:loopctl, :delivery, :dispatch_route_busy]`); it never raises for that.
  """
  @spec dispatch_route(Ecto.UUID.t(), Story.t()) ::
          {:ok,
           %{
             mode: :pr | :thread | nil,
             branch: String.t() | nil,
             base_branch: String.t() | nil
           }}
          | {:error, term()}
  def dispatch_route(tenant_id, %Story{} = story),
    do: dispatch_route(tenant_id, story, story.claim_epoch)

  @doc """
  `dispatch_route/2` for the claim of `claim_epoch` rather than the current one (US-45.7): the
  route a checkpoint recorded under an earlier claim was built on. Same lock bound, same `:busy`.
  """
  @spec dispatch_route(Ecto.UUID.t(), Story.t(), non_neg_integer()) ::
          {:ok,
           %{
             mode: :pr | :thread | nil,
             branch: String.t() | nil,
             base_branch: String.t() | nil
           }}
          | {:error, term()}
  def dispatch_route(tenant_id, %Story{} = story, claim_epoch) do
    Stages.answering_busy(
      tenant_id,
      [:loopctl, :delivery, :dispatch_route_busy],
      "dispatch route read",
      fn ->
        tenant_id
        |> Repo.with_tenant(fn ->
          # A lock held on the ledger (a retention prune, a migration) costs the gate a bounded
          # wait and an `:unevaluated` answer, never a request held open behind it.
          Capacity.set_lock_timeout!(Repo)
          Repo.one(DispatchLedger.claim_route_query(tenant_id, story.id, claim_epoch))
        end)
        |> route()
      end
    )
  end

  defp route({:ok, nil}), do: {:ok, %{mode: nil, branch: nil, base_branch: nil}}
  defp route({:ok, row}), do: {:ok, %{row | mode: route_mode(row.mode)}}
  defp route({:error, _reason} = error), do: error

  defp route_mode("thread"), do: :thread
  defp route_mode(_pr_or_legacy), do: :pr

  @doc """
  The base branch a claim was PLACED on, from its `dispatch_route/2`, so repointing the source
  afterwards cannot move the base a placed story is judged against or merged onto. A ledger
  row written before the column existed records none and falls back to `source`'s current base
  branch — the only base there was when it was placed. The one derivation of it: the merge gate
  and the merge executor both read it here (US-45.4, US-45.5).
  """
  @spec placed_base_branch(map(), map()) :: String.t()
  def placed_base_branch(%{base_branch: base_branch}, _source) when is_binary(base_branch),
    do: base_branch

  def placed_base_branch(_route, source), do: source.base_branch

  @doc """
  The branch a THREAD-mode story is judged on (US-45.4), the first that is present:

  1. the route's `branch` (`dispatch_route/2`), the name the CURRENT claim's dispatch put on
     the wire
  2. `stage_branch` — the `branch` effect a runner reported on the stage row, for a claim whose
     row records no branch (written before that column). It comes second because the stage
     row OUTLIVES a claim: a release does not clear `branch`, so after a re-claim onto a
     machine declaring another prefix it still names the PREVIOUS claim's branch, whose head
     is not among the current claim's checkpoints (US-45.4 review round 3, finding 1)
  3. `branch_for/2` with no prefixes, for a story nothing names a branch for: the name such a
     dispatch carried whenever its runner declared none. For one that did, the forge answers
     it as missing

  Only thread mode asks: a pull request names its own head, so the pr path never resolves one.
  """
  @spec thread_branch(
          %{:branch => String.t() | nil, optional(atom()) => term()},
          Story.t(),
          String.t() | nil
        ) ::
          {:ok, String.t()} | {:error, {:no_conforming_branch, [String.t()]}}
  def thread_branch(%{branch: branch}, %Story{}, _stage_branch) when is_binary(branch),
    do: {:ok, branch}

  def thread_branch(_route, %Story{}, stage_branch) when is_binary(stage_branch),
    do: {:ok, stage_branch}

  def thread_branch(_route, %Story{} = story, _stage_branch), do: branch_for(story, [])

  @doc """
  The part of a branch name that makes it this story's and nobody else's.

  The story NUMBER is unique only within its project and two projects may hold intake sources
  naming one repository, so the number alone would let two stories share a branch. Public
  because a refusal has to NAME it: a caller told only that its branch is not unique cannot
  act, and this is the string it has to end with.
  """
  @spec story_suffix(Story.t()) :: String.t()
  def story_suffix(%Story{} = story), do: "story-#{story.number}-#{String.slice(story.id, 0, 8)}"

  @doc """
  Judges EVERY field of `dispatch` that becomes a git ref, from the contract's own declaration
  of which those are (`RunnerDispatch.ref_fields/0`).

  ONE PLACE, AND IT IS READ FROM A LIST RATHER THAN WRITTEN AS A PAIR OF LITERALS (846.2
  review round 2, findings 1, 2 and 7). Round 1 closed an argument-injection on `branch` by
  checking `branch`; round 2 found `base_branch` open on the identical schema one line above,
  a non-string `branch` skipping the check entirely, and a caller-supplied `branch` defeating
  the uniqueness the contract publishes. Three leaks, each closable by naming a fourth
  spelling — the shape KB `909ba2b2` names, where a guard enumerates dangerous spellings
  instead of proving a property. The list is the contract's, the classification there is
  TOTAL over the schema's string properties, and a test fails when a new string field is
  classified as neither.

  Three refusals, and each is a fact about the values in THIS request rather than about any
  machine, which is why none of them is relaxed by `:prefix_policy` — see `fill/3`:

  - a value that is present and NOT A STRING is `{:invalid_branch_name, field, value}`. It
    used to be deferred to `cast_dispatch/1`, which runs inside `Loopctl.Runners.dispatch/3` —
    AFTER the claim, the mint and two immutable chain entries — so `{"branch": null}` claimed a
    story and was refused afterwards, making "Nothing was claimed" false in the 422 body that
    said it. That is now the LIKELY shape rather than an edge case: `branch` became optional
    and is documented OMIT THIS, and a generated client serialises an unset optional as `null`.
  - a string that is not a git ref name is the same tuple. `RunnerDispatch` declares these
    fields as 1..255 characters with NO pattern, so `--upload-pack=/bin/sh`, `-o` and `a..b`
    all cast clean and reached a machine that hands the value to git.
  - a `:story_unique` field that does not carry the story's suffix is
    `{:branch_not_unique, field, value, suffix}`. The contract publishes that two stories on
    one repository can never share a branch; `branch_allowed?/2` checks only the prefix, so
    two placements naming `loop/mine` both succeeded onto one branch and the second session
    would find the first's work there. A caller may still choose the PREFIX — what it may not
    do is drop the part that makes the name unique.

  CALLED TWICE BY `fill/3`, on the caller's own map and again on the finished payload. The
  first call is what makes a caller's value cost nothing; the second is what makes the claim
  "every value that becomes a git ref is validated" true rather than "every value the caller
  sent" — `base_branch` is filled from the project's INTAKE SOURCE when the caller omits it,
  which is a row an operator edits and which nothing else here judges.
  """
  @spec validate_refs(map(), Story.t()) :: :ok | {:error, error()}
  def validate_refs(%{} = dispatch, %Story{} = story) do
    Enum.reduce_while(RunnerDispatch.ref_fields(), :ok, fn {field, disposition}, :ok ->
      case Map.fetch(dispatch, Atom.to_string(field)) do
        :error -> {:cont, :ok}
        {:ok, value} -> judge_ref(field, value, disposition, story)
      end
    end)
  end

  defp judge_ref(field, value, _disposition, _story) when not is_binary(value),
    do: {:halt, {:error, {:invalid_branch_name, field, value}}}

  defp judge_ref(field, value, disposition, story) do
    suffix = story_suffix(story)

    cond do
      not valid_caller_branch?(value) ->
        {:halt, {:error, {:invalid_branch_name, field, value}}}

      disposition == :story_unique and not String.ends_with?(value, suffix) ->
        {:halt, {:error, {:branch_not_unique, field, value, suffix}}}

      true ->
        {:cont, :ok}
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

  # The composed name, against the rules AND the derivation's own length bound.
  defp valid_branch?(branch) do
    valid_ref_name?(branch) and byte_size(branch) <= @max_branch_length
  end

  # A name a CALLER supplied, against the same rules and the CONTRACT's bound. Read from
  # `RunnerDispatch` rather than copied, so a change to the published field cannot leave a
  # second number here disagreeing with it.
  defp valid_caller_branch?(branch) do
    valid_ref_name?(branch) and byte_size(branch) <= RunnerDispatch.max_branch_length()
  end

  # THE RULE ITSELF LIVES IN `Loopctl.GitRef` and is not restated here (#874 review round 2,
  # finding 1). It used to be private to this module, which judged a CALLER's ref fields —
  # while `intake_sources.base_branch`, settable through the API and validated only by length,
  # reached git through `Loopctl.Delivery.TriageDispatcher` without ever passing `fill/3`.
  # Writing a second copy of the predicate next to that schema is the same defect one step
  # later: two copies drift, and the weaker one is the one an attacker reaches. Both sites
  # call one definition, and neither owns it.
  defp valid_ref_name?(branch), do: GitRef.valid_name?(branch)

  # A CALLER'S OWN BRANCH IS NEVER REWRITTEN, only judged. Every other field here follows the
  # module's rule that a caller's value wins, and a control plane that silently renamed the
  # branch an operator asked for would be worse than one that refuses: the session would run,
  # on a name nobody named, and the operator would go looking for work on the other one.
  #
  # WHAT IS LEFT HERE IS THE ONE QUESTION ABOUT ANOTHER MACHINE: does the name start with a
  # prefix the target runner declared. Everything that is a fact about the VALUE — its type,
  # its shape as a git ref, and the story suffix that keeps two stories off one branch — was
  # settled by `validate_refs/2` before this ran, for every ref field at once rather than for
  # `branch` alone (846.2 review round 2). `:advise` turns THIS check off, and only this one,
  # because a prefix is the only part a rejoin can change under a caller whose claim is
  # already standing.
  #
  # The non-string clause that used to sit here is gone rather than moved: `validate_refs/2`
  # refuses a non-binary before this function is reached, so a second clause for it would be
  # the unreachable-guard defect this branch's round 1 was itself about.
  defp fill_branch(dispatch, story, prefixes, policy) do
    case Map.fetch(dispatch, "branch") do
      {:ok, branch} ->
        judge_caller_branch(dispatch, branch, prefixes, policy)

      :error ->
        with {:ok, branch} <- derive_branch(story, prefixes, policy),
             do: {:ok, Map.put(dispatch, "branch", branch)}
    end
  end

  defp judge_caller_branch(dispatch, branch, prefixes, policy) do
    cond do
      policy == :advise -> {:ok, dispatch}
      branch_allowed?(branch, prefixes) -> {:ok, dispatch}
      true -> {:error, {:branch_not_allowed, branch, prefixes}}
    end
  end

  # `:advise` FALLS BACK RATHER THAN REFUSING, and the fallback is the un-prefixed derivation
  # — the name this module produced before the field existed, which is always valid. The
  # runner may still refuse that name, and on the resume path that refusal is the right place
  # for it: it reaches a person and costs no claim, the trade `Runners.dispatch/3` documents.
  defp derive_branch(story, prefixes, :advise) do
    case branch_for(story, prefixes) do
      {:ok, _branch} = ok -> ok
      {:error, {:no_conforming_branch, _}} -> branch_for(story, [])
    end
  end

  defp derive_branch(story, prefixes, :refuse), do: branch_for(story, prefixes)

  # The MODE rides the same resolution as `repo` and `base_branch` (US-45.4): where this reads
  # the source, its mode comes from that one read; where the caller supplied both refs, the
  # same resolution runs for the mode alone, and a project with no single live source places
  # with none.
  defp fill_repo(tenant_id, story, dispatch) do
    if Map.has_key?(dispatch, "repo") and Map.has_key?(dispatch, "base_branch") do
      {:ok, put_placed_mode(dispatch, source_mode(tenant_id, story.project_id))}
    else
      with {:ok, source} <- Intake.source_for_project(tenant_id, story.project_id) do
        {:ok,
         dispatch
         |> put_new("repo", source.repo_full_name)
         |> put_new("base_branch", source.base_branch)
         |> put_placed_mode(source.mode)}
      end
    end
  end

  # An ATOM key, so a caller's JSON can never carry one. Carried for every kind: the ledger
  # records it on an implement row only (`DispatchLedger.record_sent/4`), the one rule.
  defp put_placed_mode(dispatch, mode), do: Map.put(dispatch, @placed_mode, mode_string(mode))

  defp source_mode(tenant_id, project_id) do
    case Intake.source_for_project(tenant_id, project_id) do
      {:ok, source} -> source.mode
      {:error, _no_single_source} -> nil
    end
  end

  defp mode_string(nil), do: nil
  defp mode_string(mode) when is_atom(mode), do: Atom.to_string(mode)

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
  defp budget_keys("review"), do: {:review_wall_clock_seconds, :review_max_turns}
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
