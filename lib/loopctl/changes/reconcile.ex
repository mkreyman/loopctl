defmodule Loopctl.Changes.Reconcile do
  @moduledoc """
  Gap and staleness detection for chg changes (US-47.3 AC-47.3.3, reworked by US-50.2):
  reconciliation, not trust in delivery.

  ## What is flagged, and when

  - **A gap.** An event stored ahead of a gap (`applied_at` NULL) for longer than
    `gap_after_seconds/0` (10 min) means the event before it was lost or is stuck.
  - **A quiet change.** A gap only reveals a lost event when a LATER one arrives, so it cannot
    catch a dropped final event or a bad secret. A change bound to a story (its current
    binding) whose story is not at a terminal stage, that has not landed, and that has had no
    event for `stale_after_seconds/0` (6 h), is flagged too. A landed change is quiet by
    design: `landed` is chg's last word on it, and its story waits at `merged` for a deploy
    that no chg event reports, so judging it by its stage alone flagged every landing six
    hours later and, a day after that, filed each as a `stuck_change` finding.

  ## Why loopctl does not pull

  There is no chg-server (Mark, 2026-10-28). Events come from per-machine outboxes that
  loopctl cannot reach, so the fill is the SENDER's: every answer to an event post, and the
  signed cursor read, tells the sender `applied_through` and the `held` seqs, and it resends
  from there (`Loopctl.Changes.Events`). What loopctl can do is notice that no sender is
  filling, and say so.

  `flag/3` marks the change's cursor `attention: "gap" | "stale"` and raises ONE operator
  alert. A flagged change is not a candidate for the same condition again, so a change that
  stays gapped alerts once, not every sweep. The next event that applies clears the flag
  (`Loopctl.Changes.Events`), and a change that gaps again later alerts again. A gap outranks
  staleness: a change already flagged `gap` is not re-flagged `stale`.

  The alert carries ids only (`ScaleAlertDeliveryWorker`'s operator-plane contract): never a
  secret, an event body or a repository name.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Binding
  alias Loopctl.Changes.Cursor
  alias Loopctl.Changes.Event
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.ScaleAlertDeliveryWorker

  @gap_after_seconds 600
  @stale_after_seconds 6 * 3_600

  @type candidate :: %{tenant_id: Ecto.UUID.t(), repo: String.t(), change_id: String.t()}
  @type condition :: :gap | :stale

  @doc "How long an event may wait ahead of a gap before the change is flagged."
  @spec gap_after_seconds() :: pos_integer()
  def gap_after_seconds, do: @gap_after_seconds

  @doc "How long a bound, non-terminal change may go without an event before it is flagged."
  @spec stale_after_seconds() :: pos_integer()
  def stale_after_seconds, do: @stale_after_seconds

  @doc """
  Changes with an event waiting ahead of a gap for longer than `gap_after_seconds/0` and not
  already flagged `gap`. Fleet-wide on `AdminRepo` (BYPASSRLS), so every join carries its
  tenant predicate; active tenants only. `now` is an input so the threshold is testable.
  """
  @spec gap_candidates(DateTime.t(), pos_integer()) :: [candidate()]
  def gap_candidates(%DateTime{} = now, limit) when is_integer(limit) and limit > 0 do
    cutoff = DateTime.add(now, -@gap_after_seconds, :second)

    AdminRepo.all(
      from e in Event,
        join: c in Cursor,
        on: c.tenant_id == e.tenant_id and c.repo == e.repo and c.change_id == e.change_id,
        join: t in Tenant,
        on: t.id == e.tenant_id,
        where: is_nil(e.applied_at) and e.inserted_at < ^cutoff and t.status == :active,
        where: is_nil(c.attention) or c.attention != "gap",
        group_by: [c.tenant_id, c.repo, c.change_id],
        order_by: [asc: min(e.inserted_at)],
        limit: ^limit,
        select: %{tenant_id: c.tenant_id, repo: c.repo, change_id: c.change_id}
    )
  end

  @doc """
  Changes CURRENTLY bound to a story that is not at a terminal stage (a story with no stage
  row yet is not terminal), with no applied `landed` event, with no event for
  `stale_after_seconds/0` and not flagged at all. Fleet-wide on `AdminRepo`, tenant predicate
  on every join; active tenants only.
  """
  @spec stale_candidates(DateTime.t(), pos_integer()) :: [candidate()]
  def stale_candidates(%DateTime{} = now, limit) when is_integer(limit) and limit > 0 do
    cutoff = DateTime.add(now, -@stale_after_seconds, :second)
    terminal = StageMachine.terminal_stages()
    landed = landed_subquery()

    AdminRepo.all(
      from c in Cursor,
        as: :cursor,
        join: b in Binding,
        on:
          b.tenant_id == c.tenant_id and b.repo == c.repo and b.change_id == c.change_id and
            is_nil(b.superseded_at),
        join: t in Tenant,
        on: t.id == c.tenant_id,
        left_join: st in StoryStage,
        on: st.tenant_id == b.tenant_id and st.story_id == b.story_id,
        where: c.last_event_at < ^cutoff and t.status == :active,
        where: is_nil(c.attention),
        where: is_nil(st.id) or st.stage not in ^terminal,
        where: not exists(subquery(landed)),
        order_by: [asc: c.last_event_at],
        limit: ^limit,
        select: %{tenant_id: c.tenant_id, repo: c.repo, change_id: c.change_id}
    )
  end

  @doc """
  Flags one change for `condition` and raises its operator alert, once.

  The write is conditional on the flag not being set to `condition` already (and, for
  `:stale`, on no flag at all), so two sweeps racing on one change alert once, and on the
  condition still holding at `now`, so an event that landed after the candidate read keeps
  a healthy change unflagged. Answers
  `:flagged`, or `:unchanged` when the change was already flagged or is gone.
  """
  @spec flag(candidate(), condition(), DateTime.t()) :: :flagged | :unchanged
  def flag(
        %{tenant_id: tenant_id, repo: repo, change_id: change_id},
        condition,
        %DateTime{} = now
      )
      when condition in [:gap, :stale] do
    label = Atom.to_string(condition)

    {:ok, count} =
      Repo.with_tenant(tenant_id, fn ->
        {count, _} =
          Repo.update_all(
            from(c in Cursor,
              as: :cursor,
              where: c.tenant_id == ^tenant_id and c.repo == ^repo and c.change_id == ^change_id,
              where: ^unflagged_for(condition),
              where: ^still_holds(condition, now)
            ),
            set: [attention: label, attention_at: now, updated_at: now]
          )

        count
      end)

    if count == 1 do
      alert(tenant_id, change_id, label, now)
      :flagged
    else
      :unchanged
    end
  end

  # An applied, routed `landed` event of the change bound as `:cursor`: chg's last word on it.
  defp landed_subquery do
    from e in Event,
      where:
        e.tenant_id == parent_as(:cursor).tenant_id and e.repo == parent_as(:cursor).repo and
          e.change_id == parent_as(:cursor).change_id and e.kind == "landed" and
          not is_nil(e.applied_at) and e.routed,
      select: 1
  end

  defp unflagged_for(:gap), do: dynamic([c], is_nil(c.attention) or c.attention != "gap")
  defp unflagged_for(:stale), do: dynamic([c], is_nil(c.attention))

  # The candidate's condition, re-judged in the flag's own UPDATE. The sweep reads candidates
  # first and flags them one by one, so an event that arrived in between (clearing a gap, or
  # ending the quiet) must keep the flag off rather than leave a healthy change flagged until
  # its next event.
  defp still_holds(:stale, now) do
    cutoff = DateTime.add(now, -@stale_after_seconds, :second)
    dynamic([c], c.last_event_at < ^cutoff)
  end

  defp still_holds(:gap, now) do
    cutoff = DateTime.add(now, -@gap_after_seconds, :second)

    waiting =
      from e in Event,
        where:
          e.tenant_id == parent_as(:cursor).tenant_id and e.repo == parent_as(:cursor).repo and
            e.change_id == parent_as(:cursor).change_id and is_nil(e.applied_at) and
            e.inserted_at < ^cutoff,
        select: 1

    dynamic(exists(subquery(waiting)))
  end

  defp alert(tenant_id, change_id, label, now) do
    :telemetry.execute([:loopctl, :changes, :attention], %{count: 1}, %{condition: label})

    Logger.error(
      "chg change needs attention: condition=#{label} tenant_id=#{tenant_id} " <>
        "change_id=#{inspect(change_id)}. No fleet sender has filled it; check the sending " <>
        "machine's outbox (chg doctor)."
    )

    payload = %{
      "alert" => "changes.#{label}",
      "metric" => "changes.#{label}",
      "value" => 1,
      "threshold" => 1,
      "window_seconds" => 0,
      "tenant_id" => tenant_id,
      "change_id" => change_id,
      "at" => DateTime.to_iso8601(now)
    }

    case %{payload: payload} |> ScaleAlertDeliveryWorker.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("change reconcile: failed to enqueue operator alert: #{inspect(reason)}")
        :ok
    end
  end
end
