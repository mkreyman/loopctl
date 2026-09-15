defmodule Loopctl.Workers.TriageTriggerWorker do
  @moduledoc """
  #803 §2/§4 — the production caller of `Loopctl.Delivery.TriageTrigger.promote/1`: drains
  `pending_triage` intake records into stories the delivery loop can see. Runs every minute
  via Oban Cron.

  Until this existed `promote/1` had no caller anywhere in `lib/` — no worker, no route, no
  controller — so its own moduledoc's claim that it replaced a hand-run production RPC was
  false. A webhook wrote a record and the record sat there.

  ## Why a drainer and not a call at the webhook

  `Loopctl.Intake.receive_github_delivery/2` records the delivery and applies it in ONE
  `AdminRepo` transaction, and that transaction is what makes a replayed delivery a no-op.
  Promoting inside it would put a story create AND `Loopctl.Delivery.Stages.open/3` — which
  runs on the RLS `Loopctl.Repo`, a different connection — inside it. The two cannot be one
  atomic unit, and a promote that failed would roll back the delivery row, so GitHub would
  redeliver an issue loopctl had already seen.

  The split gives both properties. The webhook writes the QUEUE ENTRY (the `Loopctl.Intake`
  moduledoc already calls the record exactly that) and nothing else; this performs the act,
  holding nothing, with a retry that is free. Free retries are load-bearing: a promote fails
  transiently on a story-number collision and on a `lock_timeout` in the stage open, and both
  clear themselves on the next pass — which a webhook has no way to ask for.

  It also means the trigger never learns how a record arrived. Records written before this
  worker existed are drained by the same read.

  ## The candidate read

  `pending_triage` records with no story the loop can SEE, fleet-wide, oldest first, on
  `AdminRepo` (BYPASSRLS, so the explicit predicates are the only scoping).

  **"No story the loop can see" is the story AND its stage row, not the story alone**, and
  that is the difference between a retry that works and one that never happens.
  `Loopctl.Delivery.Placement` selects on the stage row and nothing else, so a promote whose
  create succeeded and whose open failed — `{:stage_not_opened, :busy}`, the outcome
  `Loopctl.Delivery.Stages` documents as ordinary and retryable — leaves a story no reader can
  reach. Against `stories.intake_record_id` ALONE that record is excluded from every later run
  and the story is stranded for ever: the one failure this worker retries would be the one it
  could never see again. Requiring the stage row makes the second promote the recovery, which
  is what `promote/1`'s two idempotency mechanisms (`stories_intake_record_uidx` surfaced as
  success, `open/3`'s `ON CONFLICT DO NOTHING`) were built for.

  A stage row is never deleted except with its story, so an ADVANCED story keeps excluding its
  record exactly as a `detected` one does.

  ## A revoked source is excluded by the predicate, not skipped in the loop

  `promote/1` returns `:source_revoked` for one, and the record can then never become a story:
  revocation is one-way (there is no unrevoke path in `Loopctl.Intake`) and
  `Source.revoke_changeset/2` clears `target_epic_id` besides. So it is neither an error a
  human can clear NOR something that will succeed later.

  It is dropped in the candidate read rather than fetched and skipped because the read is
  oldest-first and bounded: a record that can never leave `pending_triage` would otherwise sit
  at the head of every batch for ever, and enough of them would starve the drain completely.
  Excluding it costs a join and no batch slot.

  It is deliberately NOT escalated. Escalation is a queue of questions for a person, and this
  one has no question in it — the repository is no longer bound, nothing can close the
  reporter's issue, and there is no action to take. Filing it would dilute the queue that
  carries `Loopctl.Delivery.InjectionDetector`'s findings. The record keeps its
  `pending_triage` status, which is what an operator reading `Intake.list_records/2` should
  see: a report that arrived and will not be worked.

  `:source_revoked` therefore reaches the loop only as a race (revoked between the read and
  the promote) and is handled there as a skip for the same reason.

  ## Escalate what a human must clear; retry everything else

  Five reasons cannot clear themselves, so retrying them is a loop that never ends:
  `:no_target_epic`, `:target_epic_missing`, `:epic_number_unnumberable`,
  `:story_number_exhausted` and `:source_not_found`. Each is answered by an operator changing
  data — naming a target epic, renumbering an epic — so each escalates the record through
  `Loopctl.Intake.escalate_record/3`, which is idempotent and appends to the audit chain.
  `:escalated` is also what takes the record out of this read.

  Everything else is left alone for the next run: a changeset error (a story-number collision,
  where the moduledoc's "the next run reads a sequence that is now free" is the remedy),
  `{:stage_not_opened, _}`, and the races where a row moved under the promote
  (`:linked_story_missing`, `{:intake_record_already_linked, nil}`, `:intake_record_not_found`,
  `:epic_not_found`). `:epic_not_found` is worth naming: it is reachable only if the epic
  vanished between `promote/1`'s own two reads, and a genuinely missing epic comes back as
  `:target_epic_missing` on the next run and escalates there. Escalating it here would file a
  question about a race, and escalation is never cleared.

  ## Bounds

  `@batch` records per run and nothing else. There is NO wall-clock budget, unlike
  `Loopctl.Workers.IntakeIssueCloseWorker` and `Loopctl.Workers.PostDeployVerificationWorker`:
  those bound a run because a candidate costs bounded NETWORK calls to a forge, and this one
  makes none at all — a candidate is a handful of local statements, and the only wait it can
  ever take is the 2s `lock_timeout` `Loopctl.Delivery.Stages` sets on its own share lock. An
  overrunning run is absorbed by the `unique` option below rather than doubling the work.

  ## How it resumes

  It holds no state. A node that dies mid-run leaves the records it had not reached exactly as
  it found them, and the next run on any node re-reads them in the same order.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    # `:retryable` is in the states for the reason `IntakeIssueCloseWorker` states: `perform/1`
    # below returns an error on a systemic failure, and without the state a backed-off job does
    # not block the next cron insert — so a minute's cadence would accumulate a retryable job
    # PLUS a fresh one every tick, each up to `max_attempts`, which is the doubling this option
    # exists to prevent.
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Delivery.TriageTrigger
  alias Loopctl.Intake
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Source
  alias Loopctl.WorkBreakdown.Story

  # Records per run. A candidate is a handful of local statements on `AdminRepo`, whose pool is
  # THREE connections that `ValidateWitnessHeader` and the Postgres rate limiter touch on every
  # authenticated request — so the bound is about not holding that pool, not about a rate
  # limit. At a minute's cadence 50 is 3,000 records an hour, orders of magnitude above any
  # webhook rate, and the read is oldest-first so a remainder is simply the next run's first
  # candidates.
  @batch 50

  @typedoc "What one candidate did. `:retrying` and `:skipped` both leave the record alone."
  @type outcome :: :promoted | :escalated | :retrying | :skipped | :errored

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results = Enum.map(candidates(), &attempt/1)
    tally = Enum.frequencies(results)

    if map_size(tally) > 0 do
      Logger.info("TriageTriggerWorker: #{inspect(tally)}")
    end

    run_result(results)
  end

  @doc false
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch

  @doc """
  The job's own result for a run whose candidates produced `results`.

  A SYSTEMIC failure must not report as a successful job, the lesson
  `Loopctl.Workers.IntakeIssueCloseWorker` records: on a connection-pool outage every
  candidate raises, the per-record rescue swallows each, and an `:ok` here would have Oban
  record a clean run — no retry, nothing discarded, nothing alerting, the failure visible only
  as log lines nobody watches. A run with some errors and some progress stays `:ok`, which is
  the one-bad-record case the rescue is for.

  Public because the whole batch failing is the one outcome a fixture cannot produce — nothing
  reachable makes `promote/1` raise — so as a private clause this rule would be code no test
  could ever contradict.
  """
  @spec run_result([outcome()]) :: :ok | {:error, {:all_candidates_errored, pos_integer()}}
  def run_result(results) when is_list(results),
    do: all_errored(Enum.count(results, &(&1 == :errored)), length(results))

  defp all_errored(count, count) when count > 0,
    do: {:error, {:all_candidates_errored, count}}

  defp all_errored(_errored, _total), do: :ok

  # ONE RECORD MAY NOT KILL THE RUN. An exception here propagates out of `perform/1`, so every
  # remaining candidate is skipped and an Oban attempt is burned — and because the read is
  # oldest-first, the record that raised sits at the head of the next batch too. That is a
  # fleet-wide stall, across every tenant, caused by one row.
  #
  # EXITS as well as raises: a `DBConnection` ownership failure and a pool checkout timeout
  # both exit rather than raise, and those are the very faults this is written for.
  defp attempt(%Record{} = record) do
    case TriageTrigger.promote(record) do
      {:ok, _story} -> :promoted
      {:error, reason} -> disposed(record, disposition(reason), reason)
    end
  rescue
    error -> errored(record, Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, value -> errored(record, Exception.format(kind, value, __STACKTRACE__))
  end

  # The five reasons a person must answer. Each is a data question — name a target epic,
  # renumber an epic, repair a record whose source is another tenant's — so none of them can
  # clear itself, and retrying one is a loop with no end.
  defp disposition(:no_target_epic), do: {:escalate, "triage_trigger:no_target_epic"}
  defp disposition(:target_epic_missing), do: {:escalate, "triage_trigger:target_epic_missing"}
  defp disposition(:source_not_found), do: {:escalate, "triage_trigger:source_not_found"}

  defp disposition(:epic_number_unnumberable),
    do: {:escalate, "triage_trigger:epic_number_unnumberable"}

  defp disposition(:story_number_exhausted),
    do: {:escalate, "triage_trigger:story_number_exhausted"}

  # Nothing to do and nobody to ask (see the moduledoc). Reachable only as a race against the
  # candidate read, which excludes revoked sources outright.
  #
  # `bin/mutate.sh` returns exit 1 on this clause — no test can tell it from the catch-all
  # below, correctly, because the read makes the race the only way in and a fixture cannot
  # stage one. It is kept because the catch-all would LOG "leaving for the next run", and there
  # is no next run for this record: it is excluded from every later read. A log line that says
  # the opposite of what happens is worse than the clause it saves.
  defp disposition(:source_revoked), do: :skip

  # Everything else self-heals on the next pass — see "Escalate what a human must clear" above.
  defp disposition(_reason), do: :retry

  defp disposed(record, {:escalate, text}, _reason), do: escalate(record, text)

  defp disposed(_record, :skip, _reason), do: :skipped

  defp disposed(record, :retry, reason) do
    Logger.info(
      "TriageTriggerWorker: leaving for the next run: " <>
        identity(record) <> " reason=#{inspect(summarised(reason))}",
      tenant_id: record.tenant_id
    )

    :retrying
  end

  defp escalate(record, text) do
    case Intake.escalate_record(record.tenant_id, record.id, text) do
      {:ok, _record} ->
        Logger.warning(
          "TriageTriggerWorker: escalated: " <> identity(record) <> " reason=#{text}",
          tenant_id: record.tenant_id
        )

        :escalated

      # The record keeps `pending_triage`, so it is a candidate again next run against a
      # condition only a person can clear — a loop nothing breaks. Counted as an error so a
      # whole batch of them fails the job where it can be seen.
      {:error, reason} ->
        errored(record, "escalation failed: #{inspect(summarised(reason))}")
    end
  end

  defp errored(record, detail) do
    Logger.error(
      "TriageTriggerWorker: candidate failed, continuing with the rest of the batch: " <>
        identity(record) <> " detail=#{detail}",
      tenant_id: record.tenant_id
    )

    :errored
  end

  # NEVER the issue title or body: those are `untrusted_*` fields and a log line is a reader.
  # The issue number and the source are loopctl's own facts and are what an operator greps.
  defp identity(%Record{} = record) do
    "tenant_id=#{record.tenant_id} record_id=#{record.id} " <>
      "source_id=#{record.source_id} issue_number=#{record.issue_number}"
  end

  # A changeset is summarised by the keys that failed; its data is an intake record and would
  # carry reporter text into the log.
  defp summarised(%Ecto.Changeset{errors: errors}), do: {:invalid_changeset, Keyword.keys(errors)}
  defp summarised(reason), do: reason

  @doc """
  The records this run will attempt, oldest first, at most `batch_size/0`.

  LEFT joins throughout, and each `nil` check means something different:

  - the SOURCE: a revoked one is excluded (see the moduledoc), while a `source_id` that
    resolves to no source OF THIS TENANT is kept — `promote/1` fails that closed with
    `:source_not_found` and the record escalates, which is a data inconsistency somebody has
    to look at rather than something to drop silently;
  - the STAGE ROW: its absence is what makes a record a candidate, story or no story.

  Neither join can multiply a row — `stories_intake_record_uidx` permits one story per
  (tenant, record) and `story_stages_tenant_story_uidx` one stage row per (tenant, story) —
  so `@batch` is exact rather than an upper bound on a fanned-out set.

  Public ONLY so the selection is falsifiable. Every exclusion here has a twin in the loop
  that produces the same visible outcome — a revoked source is skipped there too, a promoted
  record promotes again idempotently — so from the outside "excluded from the read" and
  "fetched and skipped" are indistinguishable, while the difference is the whole point: a
  record that can never leave `pending_triage` occupies a slot in every oldest-first batch for
  ever, and enough of them starve the drain. `perform/1` calls this itself.
  """
  @spec candidates() :: [Record.t()]
  def candidates do
    from(r in Record,
      left_join: src in Source,
      on: src.id == r.source_id and src.tenant_id == r.tenant_id,
      left_join: s in Story,
      on: s.intake_record_id == r.id and s.tenant_id == r.tenant_id,
      left_join: st in StoryStage,
      on: st.story_id == s.id and st.tenant_id == s.tenant_id,
      where: r.status == :pending_triage,
      where: is_nil(src.id) or is_nil(src.revoked_at),
      where: is_nil(st.id),
      order_by: [asc: r.inserted_at, asc: r.id],
      limit: @batch,
      select: r
    )
    |> AdminRepo.all()
  end
end
