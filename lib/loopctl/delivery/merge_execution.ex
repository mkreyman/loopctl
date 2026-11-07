defmodule Loopctl.Delivery.MergeExecution do
  @moduledoc """
  The pull-request route's MERGE (Epic 48, US-48.17): control decides, the runner executes.

  A pr-mode session stops at a green pull request and does not merge (AC-48.17.1, the
  runner's prompt and a claude-config hook). From there this module carries the story:

  1. **`sweep/1`**, once a minute from `Loopctl.Workers.MergeSweepWorker`, reads every story at
     `ci` on the pull-request route whose stage row names a runner, and for each one
     - holds the claim open while the runner is live (AC-48.17.3), or escalates the story over
       `:runner_gone` once the runner has had no live socket for longer than
       `runner_gone_after_seconds/0`;
     - enqueues ONE `Loopctl.Workers.MergeInstructionWorker` job when the story is verified at
       its recorded head (`verified_head_sha == head_sha`) and no instruction for that head is
       outstanding (`instruction_due?/2`).
  2. **`instruct/2`**, the job, re-reads the row, runs `MergePrecondition.enforce/3` over the
     recorded head as CONTROL, and on `:allow` pushes a `merge` instruction
     (`RunnerMergeInstruction`, contract 1.29.0) to the runner holding the claim, then records
     the send on the row (`Stages.record_merge_instruction/4`).
  3. The runner merges exactly that head (`gh pr merge --squash --match-head-commit`) and
     reports `ci -> merged` with the `merge_sha` — the path `Loopctl.Delivery.RunnerStages`
     already had. A merge reported for a head the gate did NOT allow is escalated over
     `:ungated_merge` in the same transaction (`Loopctl.Delivery.Stages.advance/4`).

  ## Every verdict of the gate

  | `enforce/3` says | what this does |
  |---|---|
  | `:allow` | pushes the instruction and records it |
  | `:refuse` | nothing: `enforce/3` already escalated over `:merge_gate` |
  | `:head_moved` | nothing: `enforce/3` already sent the story back over `:base_moved` |
  | `:unevaluated` | snoozes the job for the forge's `retry_after`, else 60 s; `enforce/3` counts it and escalates past its own bound |
  | `:already_merged` | adopts it: `ci -> merged` with the verdict's `merge_sha`, as control. `enforce/3` answers this only when the recorded allow names the merged head |

  ## Once per head: the instruction record

  The instruction is pushed FIRST and recorded SECOND, in `story_stages.merge_instruction`
  (`%{"head_sha", "runner_id", "dispatch_id", "sends", "refusals", "sent_at", "outcome"}`). The
  record is head-keyed, so a new head is a new instruction and nothing carries over.

  - A PUSHED instruction is not sent again for that head until `answer_window_seconds/0` have
    passed with no merge reported. Then it is sent again (the runner may have dropped it — a
    channel that died between the broadcast and the push, a node of an earlier release that
    ignored the message), at most `max_sends/0` times in all. Past that, the story is escalated
    over `:merge_unanswered`.
  - A push that was REFUSED (no live socket, a runner on a contract older than 1.29.0, no
    accepted dispatch for the claim) is retried after `refusal_retry_seconds/0`, at most
    `max_refusals/0` times, then escalated the same way. A failed push is the one case that is
    retried promptly, because nothing reached the runner.
  - A node dying between the push and the record sends ONE extra instruction on the next
    sweep, never zero. That is harmless by construction: the runner merges with
    `--match-head-commit`, and an instruction for a head already merged is answered by
    reporting that merge again, which the stage machine treats as the replay it is.
  - Two jobs never push at once: the job is unique per `(story_id, head_sha)` over its
    incomplete states, and each job re-reads the record before pushing.
  - Every resend runs the gate again, so a pull request the runner merged but never reported
    is found `:already_merged` and adopted rather than instructed twice.

  ## The lease, and a runner that is gone (AC-48.17.3)

  CONTROL holds the claim open; the runner does not renew it. A runner-placed claim is capped
  (#879) and `Progress.renew_claim/3` deliberately writes nothing on a capped claim, because a
  session's own word must not extend its own claim. Here no word from the session is taken:
  the sweep moves the cap forward (`Progress.extend_ci_hold_lease/3`) only for a story whose
  stage row is at `ci` on the pull-request route, whose claim is live at the row's epoch, and
  whose runner it can SEE live in Presence — and never past the implement dispatch's own
  credential expiry (`dispatches.expires_at` of `implementer_dispatch_id`), the bound every
  other part of the session already lives under. The epoch is never touched, so a zombie on an
  older epoch stays fenced; the cap only moves forward. It moves only when it is within
  `renew_within_seconds/0` of passing, so a waiting story costs one audit row per
  `hold_seconds/0`, not one per sweep.

  A runner with no live socket stops its claim being held, and starts a clock
  (`story_stages.runner_absence`). Any sweep that sees it live again clears the clock. Past
  `runner_gone_after_seconds/0` — shorter, by two sweeps, than the `renew_within_seconds/0` a
  live sweep always leaves on the lease, so the claim cannot lapse first — the
  story is escalated over `:runner_gone`, NOT re-queued: the pull request is open, green and
  verified, and re-queuing would start a fresh implement session on finished work. Past the
  dispatch's credential expiry the hold stops and the lease reclaim does what it always did.

  ## Partitions, restarts and slow connections

  Nothing is held in memory: every decision reads the stage row, the story and Presence
  afresh, and every write is fenced by the claim epoch and the row's stage. A node that
  restarts mid-job leaves the job to Oban's retry; a node that restarts mid-sweep leaves the
  next minute's sweep to repeat it. Presence is eventually consistent across nodes, so a
  runner can read absent for a sweep or two after a reconnect: the clock absorbs that, and any
  live sighting resets it. The forge is read only by the gate, before any transaction opens.

  ## Custody

  Routeless, so it gates itself, as `Loopctl.Delivery.Placement` does: a halted tenant is
  skipped by the sweep and snoozed by the job (nothing is extended, escalated or instructed
  under a halt), and a tenant that is not human-anchored is skipped and its job cancelled
  (`:custody_tier_required`). Registered in `Loopctl.Tenants.TierCapabilities` and
  `Loopctl.Custody.ContextSurface`. Every write is attributed to CONTROL
  (`"control:merge_execution"`, role `:agent`, an empty lineage — no dispatch minted it), and
  every identity the instruction carries is read from rows control wrote: the stage row, the
  verdict, the dispatch ledger. Nothing from a runner is an input.

  ## Inputs

  The clock (`:now`), the runner liveness read (`:live?`), the push (`:instruct`), the gate
  (`:enforce`), the enqueue (`:enqueue`) and the instruction switch (`:enabled?`) are options
  whose defaults are the production calls, so a test passes its own instead of touching a
  global.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.DispatchDriver
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.MergePrecondition.Verdict
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Intake.Source
  alias Loopctl.Progress
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Tenants
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.MergeInstructionWorker

  @actor_label "control:merge_execution"

  # How long a runner has to report the merge an instruction asked for before it is sent
  # again. A squash merge is one API call; ten minutes covers a runner that is busy, queued
  # behind a session or reconnecting, and is short beside the hour a person would otherwise
  # spend noticing a stuck pull request.
  @answer_window_seconds 600
  @max_sends 3

  # A push that never reached the runner is retried at the sweep's own cadence, and bounded
  # so a runner that can never take one (an old contract) escalates rather than waits for ever.
  @refusal_retry_seconds 60
  @max_refusals 10

  # The runner-gone bound. SHORTER than what is left of the hold at the last live sweep, so a
  # story whose runner vanished is escalated while its claim is still held rather than
  # reclaimed and re-queued by the lease sweep. A live sweep leaves at least
  # `@renew_within_seconds` on the lease (it renews below that), the absence clock starts at
  # most one sweep later, and the escalation fires at most one sweep after the bound: so the
  # renewal threshold must exceed the bound by two sweep intervals, checked at compile time.
  @runner_gone_after_seconds 600
  @hold_seconds 1_800
  @renew_within_seconds 1_200
  @sweep_interval_seconds 60

  if @renew_within_seconds <= @runner_gone_after_seconds + 2 * @sweep_interval_seconds or
       @renew_within_seconds >= @hold_seconds do
    raise CompileError,
      description:
        "MergeExecution: renew_within (#{@renew_within_seconds}) must exceed runner_gone " <>
          "(#{@runner_gone_after_seconds}) by two sweeps and stay below the hold (#{@hold_seconds})"
  end

  @halt_snooze_seconds 300
  @unevaluated_snooze_seconds 60
  @default_limit 100

  @type deps :: keyword()

  @doc "Seconds a pushed instruction waits for its merge report before it is sent again."
  @spec answer_window_seconds() :: pos_integer()
  def answer_window_seconds, do: @answer_window_seconds

  @doc "How many times one head's instruction is pushed before the story is escalated."
  @spec max_sends() :: pos_integer()
  def max_sends, do: @max_sends

  @doc "Seconds before a REFUSED push is tried again."
  @spec refusal_retry_seconds() :: pos_integer()
  def refusal_retry_seconds, do: @refusal_retry_seconds

  @doc "How many refused pushes for one head before the story is escalated."
  @spec max_refusals() :: pos_integer()
  def max_refusals, do: @max_refusals

  @doc "Seconds a story's runner may have no live socket before the story is escalated."
  @spec runner_gone_after_seconds() :: pos_integer()
  def runner_gone_after_seconds, do: @runner_gone_after_seconds

  @doc "How far ahead the claim is held while its runner is live, bounded by the dispatch."
  @spec hold_seconds() :: pos_integer()
  def hold_seconds, do: @hold_seconds

  @doc "The claim is held again once its cap is this close to passing."
  @spec renew_within_seconds() :: pos_integer()
  def renew_within_seconds, do: @renew_within_seconds

  # --- the sweep ------------------------------------------------------------------------

  @doc """
  One pass over the pull-request-route stories at `ci` (see the moduledoc). Returns one
  outcome per story read, in the order read:

  - `:held` — the runner is live; the claim was held open if it needed to be
  - `:instruction_enqueued` — as `:held`, and a merge instruction job was enqueued
  - `:runner_absent` — the runner has no live socket; the clock runs
  - `:runner_gone` — the clock passed its bound and the story was escalated
  - `:moved_on` — the clock passed its bound, but the locked row no longer named that runner
    (or had left `ci`), so nothing was escalated
  - `{:skipped, :tenant_halted | :custody_tier_required}` — the tenant's custody surface is
    closed, so nothing was read further or written
  - `{:error, reason}` — a write was refused; the next sweep tries again

  ## Options

  `:limit` (default #{@default_limit}), `:tenant_id` (scope to one tenant), `:now`, `:live?`
  (`(tenant_id, runner_id) -> boolean`), `:enqueue` (`(args) -> :ok`), `:enabled?` (whether
  instructions are sent at all; default `Loopctl.Delivery.DispatchDriver.enabled?/0`).
  """
  @spec sweep(deps()) :: [term()]
  def sweep(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    opts = Keyword.put(opts, :now, now)

    sweep_pages(opts, nil, %{}, [])
  end

  # Every candidate, every sweep, a page of `:limit` at a time in key order. A fixed batch
  # ordered by `updated_at` starved row `limit + 1` for ever, because the common outcomes
  # (`:held` inside the window, a repeated absence, a closed tenant) write no stage row and
  # so never rotate to the back.
  defp sweep_pages(opts, cursor, open, acc) do
    limit = Keyword.get(opts, :limit, @default_limit)
    rows = candidates(opts, cursor, limit)

    {outcomes, open} =
      Enum.map_reduce(rows, open, fn row, open ->
        {tenant_open, open} = tenant_open(open, row.tenant_id)
        {sweep_row(row, tenant_open, opts), open}
      end)

    acc = [outcomes | acc]

    if length(rows) < limit do
      acc |> Enum.reverse() |> List.flatten()
    else
      last = List.last(rows)
      sweep_pages(opts, {last.tenant_id, last.story_id}, open, acc)
    end
  end

  # The custody surface, judged once per tenant per sweep.
  defp tenant_open(open, tenant_id) do
    case Map.fetch(open, tenant_id) do
      {:ok, answer} ->
        {answer, open}

      :error ->
        answer = custody_answer(tenant_id)
        {answer, Map.put(open, tenant_id, answer)}
    end
  end

  defp custody_answer(tenant_id) do
    cond do
      Runners.custody_halted?(tenant_id) -> {:closed, :tenant_halted}
      Tenants.require_human_anchor(tenant_id) != :ok -> {:closed, :custody_tier_required}
      true -> :open
    end
  end

  defp sweep_row(_row, {:closed, why}, _opts), do: {:skipped, why}

  defp sweep_row(row, :open, opts) do
    if live?(opts).(row.tenant_id, row.runner_id),
      do: live_row(row, opts),
      else: absent_row(row, opts)
  end

  defp live_row(row, opts) do
    with :ok <- clear_absence(row),
         :ok <- hold_claim(row, opts) do
      maybe_enqueue(row, opts)
    end
  end

  defp clear_absence(%{runner_absence: nil}), do: :ok

  defp clear_absence(row) do
    case Stages.clear_runner_absence(row.tenant_id, row.story_id, write_opts(row)) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The hold: forward only, never past the implement dispatch's credential, and only once the
  # cap is close to passing. An uncapped claim (`claim_lease_cap` NULL) has nothing to hold.
  defp hold_claim(%{claim_lease_cap: nil}, _opts), do: :ok
  defp hold_claim(%{ceiling: nil}, _opts), do: :ok

  defp hold_claim(row, opts) do
    now = Keyword.fetch!(opts, :now)

    cond do
      # A verified story is `reported_done`: its claim has ended and the reclaimer never
      # touches it, so there is nothing to hold and no transaction to open. Judged again
      # under the lock by `extend_ci_hold_lease/3`; this read only saves the round trip.
      not Progress.live_claim?(
        %Story{agent_status: row.agent_status, claimed_until: row.claimed_until},
        now
      ) ->
        :ok

      # The lease the reclaimer reads is `claimed_until`; the hold keeps it equal to the cap,
      # but judging the earlier of the two means a lease that ever trailed the cap is renewed.
      DateTime.diff(earlier(row.claimed_until || row.claim_lease_cap, row.claim_lease_cap), now) >
          @renew_within_seconds ->
        :ok

      true ->
        extend(row, earlier(DateTime.add(now, @hold_seconds), row.ceiling))
    end
  end

  defp extend(row, until) do
    if DateTime.after?(until, row.claim_lease_cap) do
      case Progress.extend_ci_hold_lease(row.tenant_id, row.story_id, %{
             claim_epoch: row.claim_epoch,
             until: until,
             actor_label: @actor_label
           }) do
        {:ok, _story} -> :ok
        # The claim at this epoch has ended (reported, verified or released): there is no
        # claim to hold, and nothing reclaims a story past `implementing` anyway.
        {:error, :claim_not_live} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp earlier(a, b), do: if(DateTime.before?(a, b), do: a, else: b)

  defp absent_row(row, opts) do
    now = Keyword.fetch!(opts, :now)

    case Stages.note_runner_absence(
           row.tenant_id,
           row.story_id,
           row.runner_id,
           now,
           write_opts(row)
         ) do
      {:ok, since} ->
        if DateTime.diff(now, since) >= @runner_gone_after_seconds,
          do: escalate_runner_gone(row, since),
          else: :runner_absent

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp escalate_runner_gone(row, since) do
    reason =
      "runner_gone: the runner #{row.runner_id} holding this story's claim has had no live " <>
        "socket since #{DateTime.to_iso8601(since)} while the story waited at ci for its " <>
        "merge. Escalated rather than re-queued: the pull request is open, and re-queuing " <>
        "would start a fresh implement session on finished work."

    case escalate(row, :runner_gone, reason, still(:runner_id, row.runner_id)) do
      :ok -> :runner_gone
      :moved_on -> :moved_on
      {:error, reason} -> {:error, reason}
    end
  end

  # A `:row_guard` for `Stages.advance/4`: the decision holds only while the LOCKED row still
  # has the value it was made on (the runner it found gone, the head it instructed).
  defp still(field, value) do
    fn stage ->
      if Map.fetch!(stage, field) == value, do: :ok, else: {:error, :stale_stage}
    end
  end

  defp maybe_enqueue(row, opts) do
    if enabled?(opts) and verified_at_head?(row) and
         instruction_due?(row.merge_instruction, row.head_sha, Keyword.fetch!(opts, :now)) do
      args = %{
        "tenant_id" => row.tenant_id,
        "story_id" => row.story_id,
        "head_sha" => row.head_sha
      }

      case enqueue(opts).(args) do
        :ok -> :instruction_enqueued
        {:error, reason} -> {:error, reason}
      end
    else
      :held
    end
  end

  defp verified_at_head?(%{head_sha: head, verified_head_sha: head}) when is_binary(head),
    do: true

  defp verified_at_head?(_row), do: false

  @doc """
  Whether an instruction for `head` is due, given the row's `merge_instruction` record and the
  instant `now`: none recorded for this head; or a pushed one older than
  `answer_window_seconds/0`; or a refused one older than `refusal_retry_seconds/0`. A due
  instruction past `max_sends/0` or `max_refusals/0` escalates rather than pushes — the job
  decides that.
  """
  @spec instruction_due?(map() | nil, String.t() | nil, DateTime.t()) :: boolean()
  def instruction_due?(%{"head_sha" => head, "sent_at" => sent_at} = record, head, now)
      when is_binary(sent_at) do
    {:ok, at, _offset} = DateTime.from_iso8601(sent_at)

    wait =
      if record["outcome"] == "pushed", do: @answer_window_seconds, else: @refusal_retry_seconds

    DateTime.diff(now, at) >= wait
  end

  def instruction_due?(_record, head, _now), do: is_binary(head)

  # The read: every stage row at `ci` that names a runner, on a project whose every live
  # intake source is in mode `pr` (`Loopctl.Intake.pr_route?/3`'s rule, here as SQL), at the
  # story's own epoch. On AdminRepo with explicit tenant predicates on every join; tenant ids
  # come back with each row and every write goes through the RLS repo.
  defp candidates(opts, cursor, limit) do
    pr_projects =
      from src in Source,
        where: is_nil(src.revoked_at),
        group_by: [src.tenant_id, src.project_id],
        having: fragment("bool_and(? = 'pr')", src.mode),
        select: %{tenant_id: src.tenant_id, project_id: src.project_id}

    from(s in StoryStage,
      join: st in Story,
      on: st.id == s.story_id and st.tenant_id == s.tenant_id,
      join: p in subquery(pr_projects),
      on: p.tenant_id == st.tenant_id and p.project_id == st.project_id,
      left_join: d in Dispatch,
      on: d.id == st.implementer_dispatch_id and d.tenant_id == st.tenant_id,
      where: s.stage == :ci and not is_nil(s.runner_id),
      where: s.claim_epoch == st.claim_epoch,
      order_by: [asc: s.tenant_id, asc: s.story_id],
      limit: ^limit,
      select: %{
        tenant_id: s.tenant_id,
        story_id: s.story_id,
        claim_epoch: st.claim_epoch,
        runner_id: s.runner_id,
        head_sha: s.head_sha,
        verified_head_sha: s.verified_head_sha,
        merge_instruction: s.merge_instruction,
        runner_absence: s.runner_absence,
        claim_lease_cap: st.claim_lease_cap,
        claimed_until: st.claimed_until,
        agent_status: st.agent_status,
        ceiling: d.expires_at
      }
    )
    |> scope_tenant(Keyword.get(opts, :tenant_id))
    |> after_cursor(cursor)
    |> AdminRepo.all()
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {tenant_id, story_id}) do
    where(
      query,
      [s],
      fragment(
        "(?, ?) > (?, ?)",
        s.tenant_id,
        s.story_id,
        type(^tenant_id, :binary_id),
        type(^story_id, :binary_id)
      )
    )
  end

  defp scope_tenant(query, nil), do: query

  defp scope_tenant(query, tenant_id),
    do: where(query, [s, st], s.tenant_id == ^tenant_id and st.tenant_id == ^tenant_id)

  # --- the job ---------------------------------------------------------------------------

  @doc """
  The merge instruction job for `%{"tenant_id", "story_id", "head_sha"}` (see the moduledoc).

  - `{:ok, :pushed}` — the gate allowed the head and the instruction reached the runner's
    channel; `{:ok, {:not_pushed, reason}}` — the push was refused and recorded, to be retried
  - `{:ok, :adopted_merge}` — the pull request was already merged at the allowed head and the
    merge was recorded
  - `{:ok, :refused | :head_moved}` — the gate acted on its own verdict
  - `{:ok, :merge_unanswered}` — the bound was reached and the story was escalated
  - `{:ok, :not_due | :not_ready}` — an instruction for this head is outstanding, or the row
    is no longer a story verified at `ci` at this head; nothing to do
  - `{:snooze, seconds}` — the forge could not be read, or the tenant is halted
  - `{:cancel, reason}` — the tenant is not human-anchored, or its route is `chg`
  - `{:error, reason}` — a write was refused; Oban retries

  ## Options

  `:now`, `:instruct` (`(tenant_id, runner_id, payload) -> :ok | {:error, reason}`, default
  `Loopctl.Runners.instruct_merge/3`), `:enforce` (default `MergePrecondition.enforce/3`).
  """
  @spec instruct(map(), deps()) ::
          {:ok, term()} | {:snooze, pos_integer()} | {:cancel, term()} | {:error, term()}
  def instruct(args, opts \\ [])

  def instruct(%{"tenant_id" => tenant_id, "story_id" => story_id, "head_sha" => head}, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with :ok <- custody_open(tenant_id),
         {:ok, %StoryStage{} = stage} <- ready_stage(tenant_id, story_id, head) do
      cond do
        not instruction_due?(stage.merge_instruction, head, now) ->
          {:ok, :not_due}

        exhausted?(stage.merge_instruction, head) ->
          escalate_unanswered(stage)

        true ->
          gate(stage, now, opts)
      end
    end
  end

  defp custody_open(tenant_id) do
    case custody_answer(tenant_id) do
      :open -> :ok
      {:closed, :tenant_halted} -> {:snooze, @halt_snooze_seconds}
      {:closed, :custody_tier_required} -> {:cancel, :custody_tier_required}
    end
  end

  # The row as it stands: at `ci`, at the job's head, verified at that head, naming a runner.
  # Anything else means the story moved on since the sweep read it, which is not an error.
  defp ready_stage(tenant_id, story_id, head) do
    case Stages.get(tenant_id, story_id) do
      %StoryStage{stage: :ci, head_sha: ^head, verified_head_sha: ^head, runner_id: runner} =
          stage
      when is_binary(runner) ->
        {:ok, stage}

      _moved_on ->
        {:ok, :not_ready}
    end
  end

  defp exhausted?(%{"head_sha" => head} = record, head) do
    Map.get(record, "sends", 0) >= @max_sends or Map.get(record, "refusals", 0) >= @max_refusals
  end

  defp exhausted?(_record, _head), do: false

  defp gate(stage, now, opts) do
    enforce = Keyword.get(opts, :enforce, &MergePrecondition.enforce/3)

    stage.tenant_id
    |> enforce.(stage.story_id,
      claim_epoch: stage.claim_epoch,
      actor_label: @actor_label,
      actor_role: :agent,
      actor_lineage: []
    )
    |> act_on(stage, now, opts)
  end

  defp act_on({:ok, %Verdict{decision: :allow} = verdict}, stage, now, opts),
    do: push(stage, verdict, now, opts)

  defp act_on({:ok, %Verdict{decision: :already_merged, merge_sha: sha}}, stage, _now, _opts),
    do: adopt_merge(stage, sha)

  defp act_on({:ok, %Verdict{decision: :unevaluated, retry_after: after_s}}, _stage, _now, _opts),
    do: {:snooze, after_s || @unevaluated_snooze_seconds}

  # `enforce/3` already acted on both: escalated over `:merge_gate`, or sent the story back.
  defp act_on({:ok, %Verdict{decision: :refuse}}, _stage, _now, _opts), do: {:ok, :refused}
  defp act_on({:ok, %Verdict{decision: :head_moved}}, _stage, _now, _opts), do: {:ok, :head_moved}

  defp act_on({:error, :change_protocol_enrolled}, _stage, _now, _opts),
    do: {:cancel, :change_protocol_enrolled}

  defp act_on({:error, reason}, _stage, _now, _opts)
       when reason in [:not_found, :no_stage, :wrong_stage],
       do: {:ok, :not_ready}

  defp act_on({:error, reason}, _stage, _now, _opts), do: {:error, reason}

  # The instruction names the dispatch the runner reports the merge under: the accepted
  # implement row of THIS claim, whose runner must be the one the stage row names. Every value
  # is control's own.
  defp push(stage, %Verdict{} = verdict, now, opts) do
    instruct = Keyword.get(opts, :instruct, &Runners.instruct_merge/3)
    dispatch = DispatchLedger.claim_dispatch(stage.tenant_id, stage.story_id, stage.claim_epoch)

    outcome =
      case dispatch do
        %{runner_id: runner_id} = dispatch when runner_id == stage.runner_id ->
          payload = %{
            "dispatch_id" => dispatch.dispatch_id,
            "claim_epoch" => stage.claim_epoch,
            "story_id" => stage.story_id,
            "repo" => verdict.repo,
            "pr_number" => verdict.pr_number,
            "head_sha" => stage.head_sha,
            "merge_method" => "squash"
          }

          instruct.(stage.tenant_id, stage.runner_id, payload)

        %{} ->
          {:error, :runner_mismatch}

        nil ->
          {:error, :no_accepted_dispatch}
      end

    record_send(stage, dispatch, outcome, now)
  end

  defp record_send(stage, dispatch, outcome, now) do
    record = next_record(stage, dispatch, outcome, now)
    log_send(stage, record)

    case Stages.record_merge_instruction(
           stage.tenant_id,
           stage.story_id,
           record,
           write_opts(stage)
         ) do
      {:ok, _row} ->
        send_result(outcome)

      # The push already happened; the next sweep re-reads the row and decides again. A record
      # that did not land costs at most one more instruction, which the runner tolerates.
      {:error, reason} ->
        Logger.warning(
          "merge instruction not recorded: tenant_id=#{stage.tenant_id} " <>
            "story_id=#{stage.story_id} reason=#{inspect(reason)} outcome=#{record["outcome"]}"
        )

        {:error, reason}
    end
  end

  # The record carries over only for the SAME head: a new head is a new instruction.
  defp next_record(stage, dispatch, outcome, now) do
    previous =
      case stage.merge_instruction do
        %{"head_sha" => head} = record when head == stage.head_sha -> record
        _none -> %{}
      end

    {sends, refusals} = if outcome == :ok, do: {1, 0}, else: {0, 1}

    %{
      "head_sha" => stage.head_sha,
      "runner_id" => stage.runner_id,
      "dispatch_id" => dispatch && dispatch.dispatch_id,
      "sends" => Map.get(previous, "sends", 0) + sends,
      "refusals" => Map.get(previous, "refusals", 0) + refusals,
      "sent_at" => DateTime.to_iso8601(now),
      "outcome" => outcome_text(outcome)
    }
  end

  defp send_result(:ok), do: {:ok, :pushed}
  defp send_result({:error, reason}), do: {:ok, {:not_pushed, reason}}

  defp outcome_text(:ok), do: "pushed"
  defp outcome_text(refused), do: refusal_text(refused)

  defp refusal_text({:error, {:invalid, _messages}}), do: "invalid"
  defp refusal_text({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp refusal_text({:error, _reason}), do: "push_failed"

  defp log_send(stage, record) do
    Logger.info(
      "merge instruction #{record["outcome"]}: tenant_id=#{stage.tenant_id} " <>
        "story_id=#{stage.story_id} runner_id=#{stage.runner_id} head_sha=#{stage.head_sha} " <>
        "sends=#{record["sends"]} refusals=#{record["refusals"]}"
    )
  end

  defp adopt_merge(stage, merge_sha) do
    case Stages.advance(stage.tenant_id, stage.story_id, {:ci, :merged},
           claim_epoch: stage.claim_epoch,
           effects: [merge_sha: merge_sha],
           actor_label: @actor_label,
           actor_role: :agent,
           actor_lineage: []
         ) do
      {:ok, _row} -> {:ok, :adopted_merge}
      # The runner's own report got there first.
      {:error, :stale_stage} -> {:ok, :not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  defp escalate_unanswered(stage) do
    record = stage.merge_instruction

    reason =
      "merge_unanswered: the merge gate allowed head #{stage.head_sha} and the runner " <>
        "#{stage.runner_id} holding the claim was instructed to merge it " <>
        "#{Map.get(record, "sends", 0)} time(s), with #{Map.get(record, "refusals", 0)} " <>
        "push(es) refused (last: #{record["outcome"]}), and no merge was reported."

    case escalate(stage, :merge_unanswered, reason, still(:head_sha, stage.head_sha)) do
      :ok -> {:ok, :merge_unanswered}
      :moved_on -> {:ok, :not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- shared ----------------------------------------------------------------------------

  defp escalate(row, edge, reason, guard) do
    case Stages.advance(row.tenant_id, row.story_id, {:ci, :escalated, edge},
           claim_epoch: row.claim_epoch,
           reason: reason,
           actor_label: @actor_label,
           actor_role: :agent,
           actor_lineage: [],
           row_guard: guard
         ) do
      {:ok, _row} ->
        Logger.warning(
          "story escalated over #{edge}: tenant_id=#{row.tenant_id} story_id=#{row.story_id}"
        )

        :ok

      # Another writer moved the row first; it is no longer this decision's to make.
      {:error, :stale_stage} ->
        :moved_on

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_opts(row), do: [claim_epoch: row.claim_epoch, actor_label: @actor_label]

  defp live?(opts),
    do:
      Keyword.get(opts, :live?, fn tenant_id, runner_id ->
        Runners.live_metas(tenant_id, runner_id) != []
      end)

  defp enqueue(opts), do: Keyword.get(opts, :enqueue, &enqueue_job/1)

  defp enabled?(opts), do: Keyword.get_lazy(opts, :enabled?, &DispatchDriver.enabled?/0)

  defp enqueue_job(args) do
    case args |> MergeInstructionWorker.new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
