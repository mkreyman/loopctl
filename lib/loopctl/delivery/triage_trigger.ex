defmodule Loopctl.Delivery.TriageTrigger do
  @moduledoc """
  Turns a reported issue into a story the delivery loop can see (issue #803 §2, §4).

  Until this existed, intake and the loop did not touch: `Loopctl.Intake` wrote a record and
  stopped, `Loopctl.Delivery.Placement` waited for a caller, and the only way to start a run
  was a production RPC by hand. This is the missing edge — the one place a
  `pending_triage` record becomes a `stories` row at the `detected` stage.

  ## What it does NOT do yet, and why that is not a half-measure

  It does not dispatch triage. `triage` is not in
  `Loopctl.ApiSpec.RunnerContract.RunnerDispatch.dispatchable_kinds/0`, because no deployed
  runner accepts the kind and a triage session needs its own contained tool set — the
  runner's work, not loopctl's. Sending it early is not merely useless: against a runner on
  the implied path one refusal writes a permanent `kind_not_supported` for that machine.

  So this lands the half that does not depend on the other side. A record becomes a story at
  `detected`, linked by `intake_record_id`, and the dispatch is one call added here when the
  interlock moves. Splitting it that way is also what lets both sides be built at once, which
  is the whole reason the payload landed before the trigger.

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

  @type error :: :no_target_epic | :source_revoked | :epic_number_unnumberable | term()

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
         {_row, _} <- Stages.open(record.tenant_id, story.id, actor_label: @actor_label) do
      {:ok, story}
    end
  end

  # A record whose source has since been revoked is not promoted. The webhook binding is gone,
  # so nothing can close the reporter's issue afterwards and a story nobody can answer is
  # worse than a record sitting still.
  defp live_source(%Record{tenant_id: tenant_id, source_id: source_id}) do
    case AdminRepo.get_by(Source, id: source_id, tenant_id: tenant_id) do
      %Source{revoked_at: nil} = source -> {:ok, source}
      _ -> {:error, :source_revoked}
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
  defp story_number(tenant_id, epic_id) do
    epic = AdminRepo.get_by!(Epic, id: epic_id, tenant_id: tenant_id)

    if epic.number >= @max_number_part do
      {:error, :epic_number_unnumberable}
    else
      {:ok, "#{epic.number}.#{next_sequence(tenant_id, epic_id, epic.number)}"}
    end
  end

  # The highest MINOR already used under this epic's MAJOR, plus one. Read off `stories` rather
  # than counted, so a deleted story does not hand its number to the next arrival.
  defp next_sequence(tenant_id, epic_id, major) do
    prefix = "#{major}."

    used =
      AdminRepo.all(
        from s in Story,
          where: s.tenant_id == ^tenant_id and s.epic_id == ^epic_id,
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
