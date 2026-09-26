defmodule Loopctl.Delivery.TriageTrigger do
  @moduledoc """
  Turns a reported issue into a story the delivery loop can see (issue #803 §2, §4).

  Until this existed, intake and the loop did not touch: `Loopctl.Intake` wrote a record and
  stopped, `Loopctl.Delivery.Placement` waited for a caller, and the only way to start a run
  was a production RPC by hand. This is the missing edge — the one place a
  `pending_triage` record becomes a `stories` row at the `detected` stage.

  ## What it does not do: dispatch the triage session

  This module only makes the stub story. Sending the triage session to a runner is
  `Loopctl.Delivery.TriageDispatcher`'s job (runner contract 1.10.0), which picks up stories at
  `detected` and sends kind `triage` only to a runner that declared it on join. The two were
  built apart so that neither side waited on the other.

  ## The stub story carries NO reporter text

  Design §10: the implementer never sees the reporter's words, and its input is the story the
  trio wrote. A stub created BEFORE triage has no trio behind it, so anything it carried from
  the report would be reporter text wearing a story's clothes — and `stories.title` is read by
  every later reader, including the implementer.

  The title is therefore loopctl's own: the repository and the issue number, which are
  loopctl's facts and not the reporter's. Triage replaces it with the drafted one.

  ## Where the story lands, and what happens when nobody said

  `intake_sources.target_epic_id`. A story requires an epic and a source only knew its
  project; the alternatives were for this worker to find-or-create an epic (making a webhook's
  arrival a writer of work-breakdown structure) or to pick one by a rule nobody declared. The
  operator says instead.

  A source that names none yields `{:error, :no_target_epic}` and the record is ESCALATED —
  the question has not been answered and guessing an answer is worse than asking. That is the
  same choice the nullable column makes and it is why the column is nullable.

  ## Running it twice is safe, and the mechanism is a unique index

  `stories_intake_record_uidx` permits at most one story per record, and
  `Loopctl.WorkBreakdown.Stories.create_story/3` surfaces a collision as
  `{:error, {:intake_record_already_linked, story_id}}` CARRYING the existing id — written for
  exactly this caller, because a create that is at-least-once over a network needs to tell its
  own lost-response success from a real conflict. This treats that error as success and
  returns the story already there.

  `Loopctl.Delivery.Stages.open/3` is idempotent the same way, on
  `(tenant_id, story_id)` with `ON CONFLICT DO NOTHING`, so a second run re-opens nothing and
  appends no second `opened` event.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Source
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.WorkBreakdown.Story

  @actor_label "worker:triage_trigger"

  # `Loopctl.WorkBreakdown.Story`'s own rule, restated here because this is the only module
  # that CONSTRUCTS a number rather than accepting one: each part of a `MAJOR.MINOR` story
  # number must be a non-negative integer below this.
  @max_number_part 10_000

  # EVERY reason this returns, spelled out and with no `| term()`. The trailing member made
  # the union unfalsifiable — dialyzer cannot contradict it, so the spec could only ever be
  # checked by reading, and it was wrong on two counts when it was: it listed a bare
  # `:stage_not_opened` that `opened/2` never returns (it is always a tuple) and omitted
  # `:linked_story_missing` entirely. A spec that cannot be wrong is a comment.
  #
  # `{:error, Ecto.Changeset.t()}` is the one open shape, and it is a real type rather than an
  # escape hatch: `Stories.create_story/3` returns a changeset for a number collision, which
  # is the case the moduledoc's retry argument is about.
  @type error ::
          :no_target_epic
          | :source_revoked
          | :epic_number_unnumberable
          | :target_epic_missing
          | :linked_story_missing
          | :intake_record_not_found
          | :story_number_exhausted
          | :source_not_found
          | {:stage_not_opened, :not_found | :busy}
          | {:intake_record_already_linked, Ecto.UUID.t() | nil}
          | :epic_not_found
          | Ecto.Changeset.t()

  @doc """
  Creates the story for `record` and opens its delivery stage at `detected`.

  Returns `{:ok, story}` — including when the story already existed, see the moduledoc — or
  `{:error, reason}`. The caller escalates the record on `:no_target_epic`.
  """
  @spec promote(Record.t()) :: {:ok, map()} | {:error, error()}
  def promote(%Record{} = record) do
    with {:ok, source} <- live_source(record),
         {:ok, epic_id} <- target_epic(source),
         {:ok, story} <- create(record, source, epic_id),
         {:ok, _row} <- opened(record.tenant_id, story.id) do
      {:ok, story}
    end
  end

  # A record whose source has since been revoked is not promoted. The webhook binding is gone,
  # so nothing can close the reporter's issue afterwards and a story nobody can answer is
  # worse than a record sitting still.
  # A story with no stage row is INVISIBLE to the loop — `Placement` selects on that row and
  # nothing else — so a failed open must not read as success. The first version matched
  # `{_row, _}`, which `{:error, :busy}` satisfies just as well as `{:ok, row}`: a
  # `lock_timeout` while the reclaimer held the story (an outcome `Stages` documents as
  # ordinary and retryable) produced `{:ok, story}` here, the caller marked the record
  # promoted, and the story sat for ever with nothing to advance it and nothing to retry it.
  #
  # The error is named rather than passed through so a caller can tell "this record has no
  # story" from "this record has a story the loop cannot see": the second is safe to retry —
  # `open/3` is idempotent on `(tenant_id, story_id)` — and the first is not the same act.
  defp opened(tenant_id, story_id) do
    case Stages.open(tenant_id, story_id, actor_label: @actor_label) do
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, {:stage_not_opened, reason}}
    end
  end

  defp live_source(%Record{tenant_id: tenant_id, source_id: source_id}) do
    # The two are DIFFERENT facts and were reported as one. A revocation is the routine,
    # expected outcome and will be filtered as noise wherever it is handled; a record whose
    # source does not resolve at all — deleted, or a tenant mismatch between record and
    # source — is the case where a human has to look at the data, and folding it into
    # `:source_revoked` hid it in exactly the bucket nobody reads.
    case AdminRepo.get_by(Source, id: source_id, tenant_id: tenant_id) do
      %Source{revoked_at: nil} = source -> {:ok, source}
      %Source{} -> {:error, :source_revoked}
      nil -> {:error, :source_not_found}
    end
  end

  defp target_epic(%Source{target_epic_id: nil}), do: {:error, :no_target_epic}
  defp target_epic(%Source{target_epic_id: id}), do: {:ok, id}

  # The collision error is SUCCESS here, and carrying the id is what makes that safe: it says
  # which story this record already has rather than only that one exists, so a retry after a
  # lost response returns the same story the first attempt created.
  #
  # It RE-READS that story rather than synthesising a map from the id. The two returns have to
  # be the same shape: this is the at-least-once path by construction, so a caller reading
  # `story.number` would work on the first attempt and raise `KeyError` on the retry — the
  # attempt that is far more likely to be the one a human is looking at when something has
  # already gone wrong.
  defp create(record, source, epic_id) do
    with {:ok, number} <- story_number(record.tenant_id, epic_id) do
      insert(record, source, epic_id, number)
    end
  end

  defp insert(record, source, epic_id, number) do
    attrs = %{
      epic_id: epic_id,
      number: number,
      title: stub_title(record, source)
    }

    case Stories.create_story(record.tenant_id, attrs,
           actor_label: @actor_label,
           intake_record_id: record.id
         ) do
      {:ok, story} ->
        {:ok, story}

      {:error, {:intake_record_already_linked, story_id}} when is_binary(story_id) ->
        Logger.info(
          "intake record #{record.id} already has story #{story_id}; returning it unchanged"
        )

        case AdminRepo.get_by(Story, id: story_id, tenant_id: record.tenant_id) do
          %Story{} = story -> {:ok, story}
          nil -> {:error, :linked_story_missing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # LOOPCTL'S OWN FACTS ONLY — the repository and the issue number. Not the reporter's title,
  # which is what a stub would naturally borrow and is exactly what design §10 forbids
  # reaching an implementer. Triage replaces this with the drafted title.
  defp stub_title(%Record{issue_number: number}, %Source{repo_full_name: repo}) do
    "Triage pending: #{repo}##{number}"
  end

  # `EPIC.SEQUENCE`, which is the convention every other story in this codebase follows —
  # story `43.1` is the first story of epic 43 — and NOT a scheme of this module's own.
  #
  # The first attempt here derived the number from the ISSUE number (`intake.412`) and could
  # never have created a story at all: `Story.validate_number_format/1` requires both parts to
  # be integers below 10_000, so `"intake"` was rejected on every record in every tenant. It
  # was caught by the tests written against this module before it reached a review.
  #
  # Following the convention also dissolves a problem the derived scheme had and I had not
  # noticed: a GitHub repository reaches issue 10_000, and any number carrying the issue
  # number in a part would have become illegal there. A sequence within the epic has no such
  # ceiling until the epic has 10_000 stories.
  #
  # NOT DETERMINISTIC, and it does not need to be. A retry that picks a different number still
  # cannot create a second story, because `stories_intake_record_uidx` permits one story per
  # record and `create/3` above treats that collision as success. Idempotency is held by the
  # index, not by the arithmetic.
  #
  # Two promotes into one epic CAN pick the same sequence — this is a read, not a reservation.
  # The unique index on `(tenant_id, project_id, number)` refuses the loser with a changeset
  # error, the record stays `pending_triage`, and the next run reads a sequence that is now
  # free. A worker whose retry is free is the right place to leave that, rather than a lock or
  # a retry loop inside one call.
  # AND IT CAN REFUSE, because the two schemas disagree and nothing had made that visible.
  # `epics.number` is validated only `greater_than: 0` — unbounded above — while a story
  # number's parts must be under 10_000. So an epic numbered 10_000 or higher is legal and
  # every story in it is unnumberable, which every hand-authored story has silently assumed
  # away. This is the first caller to construct one programmatically and therefore the first
  # to meet it; it was found by the full suite, where the fixture's epic numbers are large,
  # after passing in isolation where they are small.
  #
  # Refused rather than worked around. A reserved MAJOR band would put this story somewhere
  # its epic's other stories are not, which is the numbering equivalent of guessing an epic —
  # and the operator's remedy, renumbering the epic, is one they can actually take. Same
  # choice as `:no_target_epic` and for the same reason.
  # `get_by`, not `get_by!`. This function's whole contract is `{:ok, _} | {:error, _}`, and a
  # `target_epic_id` that resolves to nothing — a deleted epic, a cross-tenant id — would
  # otherwise raise `Ecto.NoResultsError` straight out of it. The caller's remedy for a
  # misconfigured source is an escalation, not a crashed worker.
  defp story_number(tenant_id, epic_id) do
    case AdminRepo.get_by(Epic, id: epic_id, tenant_id: tenant_id) do
      nil ->
        {:error, :target_epic_missing}

      %Epic{number: number} when number >= @max_number_part ->
        {:error, :epic_number_unnumberable}

      %Epic{} = epic ->
        numbered(epic, next_sequence(tenant_id, epic))
    end
  end

  # The highest MINOR already used under this MAJOR anywhere in the PROJECT, plus one.
  #
  # Scoped to the project and not to the epic, because that is the scope the uniqueness has:
  # `stories_tenant_id_project_id_number_index` is project-wide and nothing ties a story's
  # MAJOR to its epic. An epic-scoped scan made the moduledoc's "the next run reads a sequence
  # that is now free" false in the case this module itself creates — renumbering an epic is
  # the remedy it recommends for `:epic_number_unnumberable`, which leaves stories numbered
  # under the OLD major, and a later epic taking that number would have its scan come back
  # empty, pick `.1`, collide on the project index and recompute the same number on every
  # retry. The record would stall in `pending_triage` for ever rather than self-heal.
  #
  # Read off `stories` rather than counted, so a deleted story does not hand its number to the
  # next arrival.
  # THE MINOR HAS THE SAME CEILING AS THE MAJOR, and guarding only the major left the failure
  # this module's own comments say the project-wide scan exists to avoid. A sequence at or
  # past 10_000 is rejected by `Story.validate_number_format/1` as an opaque changeset error,
  # and it does not self-heal: every retry rescans, computes the same max plus one, and fails
  # identically, so the record stalls in `pending_triage` for ever.
  #
  # It does not take 10_000 stories to get there. The scan is project-wide and reads whatever
  # is in `stories`, so a single hand-authored `43.9999` anywhere in the project makes the
  # next promote under epic 43 produce `43.10000`.
  defp numbered(%Epic{number: major}, minor) when minor < @max_number_part,
    do: {:ok, "#{major}.#{minor}"}

  defp numbered(%Epic{}, _minor), do: {:error, :story_number_exhausted}

  # Takes the `%Epic{}` `story_number/2` already loaded — tenant-scoped — rather than reading
  # it again by id alone. The re-read was a second round trip on `AdminRepo`'s 3-connection
  # pool for a row that was in hand, and it was the one query in this module carrying no
  # `tenant_id` predicate, against the rule every other read here follows.
  defp next_sequence(tenant_id, %Epic{project_id: project_id, number: major}) do
    prefix = "#{major}."

    used =
      AdminRepo.all(
        from s in Story,
          where: s.tenant_id == ^tenant_id and s.project_id == ^project_id,
          where: like(s.number, ^(prefix <> "%")),
          select: s.number
      )

    used
    |> Enum.map(&minor_of(&1, prefix))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp minor_of(number, prefix) do
    case Integer.parse(String.replace_prefix(number, prefix, "")) do
      {n, ""} -> n
      _ -> 0
    end
  end
end
