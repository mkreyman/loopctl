defmodule Loopctl.Changes.Reconcile do
  @moduledoc """
  Gap and staleness reconciliation for chg changes (US-47.3, AC-47.3.3; Epic 47 PRD §5):
  reconciliation, not trust in delivery.

  ## What is pulled, and when

  - **A gap.** An event stored ahead of a gap (`applied_at` NULL) for longer than
    `gap_after_seconds/0` (10 min) means the event before it was lost or is stuck. Delivery
    alone cannot fix that, so the change is pulled.
  - **A quiet change.** A gap only reveals a lost event when a LATER one arrives, so it cannot
    catch a dropped final event or a bad secret. A change bound to a story (its current
    binding) whose story is not at a terminal stage, and that has had no event for
    `stale_after_seconds/0` (6 h), is pulled too.

  Either way a change is pulled at most once per its interval (`change_cursors.last_pulled_at`),
  so an idle change, or a chg-server that keeps refusing, is not asked on every sweep.
  `Loopctl.Workers.ChangeReconcileSweepWorker` finds the candidates and enqueues ONE
  `Loopctl.Workers.ChangeReconcileWorker` job per change, unique on the change.

  ## The pull

  `pull/4` asks chg-server for the change's events after its applied `event_seq`
  (`Loopctl.Changes.ChgClient`, signed with the repository's live `:chg` source's secret) and
  ingests them through `Loopctl.Changes.Events.ingest_pulled/3` — the same validation, source
  hold, root check, ordering, idempotency and audit as a push. A pulled envelope for another
  change or repository is dropped. It pages while the cursor advances, up to `:max_pages`.

  **A pull refused for its signature raises an operator alert** (`ScaleAlertDeliveryWorker`,
  the operator-plane channel, plus an error log): under a one-sided secret rotation it is the
  only signal loopctl gets, because chg alerts on its own surfaces and never through loopctl.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Binding
  alias Loopctl.Changes.ChgClient
  alias Loopctl.Changes.Cursor
  alias Loopctl.Changes.Envelope
  alias Loopctl.Changes.Event
  alias Loopctl.Changes.Events
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake
  alias Loopctl.Intake.Source
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.ScaleAlertDeliveryWorker

  @gap_after_seconds 600
  @stale_after_seconds 6 * 3_600
  @default_max_pages 10

  @type candidate :: %{tenant_id: Ecto.UUID.t(), repo: String.t(), change_id: String.t()}

  @doc "How long an event may wait ahead of a gap before the change is pulled."
  @spec gap_after_seconds() :: pos_integer()
  def gap_after_seconds, do: @gap_after_seconds

  @doc "How long a bound, non-terminal change may go without an event before it is pulled."
  @spec stale_after_seconds() :: pos_integer()
  def stale_after_seconds, do: @stale_after_seconds

  @doc """
  Changes with an event waiting ahead of a gap for longer than `gap_after_seconds/0`, not
  pulled within that interval. Fleet-wide on `AdminRepo` (BYPASSRLS), so every join carries
  its tenant predicate; active tenants only. `now` is an input so the threshold is testable.
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
        where: is_nil(c.last_pulled_at) or c.last_pulled_at < ^cutoff,
        group_by: [c.tenant_id, c.repo, c.change_id],
        order_by: [asc: min(e.inserted_at)],
        limit: ^limit,
        select: %{tenant_id: c.tenant_id, repo: c.repo, change_id: c.change_id}
    )
  end

  @doc """
  Changes CURRENTLY bound to a story that is not at a terminal stage (a story with no stage
  row yet is not terminal), with no event for `stale_after_seconds/0` and not pulled within
  it. Fleet-wide on `AdminRepo`, tenant predicate on every join; active tenants only.
  """
  @spec stale_candidates(DateTime.t(), pos_integer()) :: [candidate()]
  def stale_candidates(%DateTime{} = now, limit) when is_integer(limit) and limit > 0 do
    cutoff = DateTime.add(now, -@stale_after_seconds, :second)
    terminal = StageMachine.terminal_stages()

    AdminRepo.all(
      from c in Cursor,
        join: b in Binding,
        on:
          b.tenant_id == c.tenant_id and b.repo == c.repo and b.change_id == c.change_id and
            is_nil(b.superseded_at),
        join: t in Tenant,
        on: t.id == c.tenant_id,
        left_join: st in StoryStage,
        on: st.tenant_id == b.tenant_id and st.story_id == b.story_id,
        where: c.last_event_at < ^cutoff and t.status == :active,
        where: is_nil(c.last_pulled_at) or c.last_pulled_at < ^cutoff,
        where: is_nil(st.id) or st.stage not in ^terminal,
        order_by: [asc: c.last_event_at],
        limit: ^limit,
        select: %{tenant_id: c.tenant_id, repo: c.repo, change_id: c.change_id}
    )
  end

  @doc """
  Pulls one change's missing events from chg-server and ingests them.

  `opts`: `:client` (default `ChgClient.impl/0`), `:base_url` (default `ChgClient.base_url/0`),
  `:max_pages`, and `:lock_timeout_ms` (passed to the ingest). Answers `{:ok, %{applied_seq:,
  pages:}}`, or `{:error, reason}`: `:chg_server_unconfigured`, `:no_chg_source`,
  `:unknown_change` and `:pull_unauthorized` are final for this attempt (the sweep asks again
  after the interval); anything else is transient and worth a retry.
  """
  @spec pull(Ecto.UUID.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{applied_seq: non_neg_integer(), pages: non_neg_integer()}}
          | {:error, term()}
  def pull(tenant_id, repo, change_id, opts \\ [])
      when is_binary(tenant_id) and is_binary(repo) and is_binary(change_id) do
    client = Keyword.get_lazy(opts, :client, &ChgClient.impl/0)
    base_url = Keyword.get_lazy(opts, :base_url, &ChgClient.base_url/0)
    max_pages = Keyword.get(opts, :max_pages, @default_max_pages)

    with {:ok, base_url} <- configured(base_url),
         {:ok, cursor} <- mark_pulled(tenant_id, repo, change_id),
         {:ok, source} <- live_source(tenant_id, repo) do
      Logger.metadata(tenant_id: tenant_id)

      pull_ctx = %{
        client: client,
        base_url: base_url,
        source: source,
        cursor: cursor,
        max_pages: max_pages,
        ingest_opts: Keyword.take(opts, [:lock_timeout_ms])
      }

      page(pull_ctx, cursor.applied_seq, 0)
    end
  end

  defp configured(url) when is_binary(url) and url != "", do: {:ok, url}
  defp configured(_url), do: {:error, :chg_server_unconfigured}

  # Stamped BEFORE the call, whatever it answers, so a chg-server that is down or refusing is
  # asked again only after the interval rather than on every sweep.
  defp mark_pulled(tenant_id, repo, change_id) do
    now = DateTime.utc_now()

    {:ok, cursor} =
      Repo.with_tenant(tenant_id, fn ->
        case Repo.update_all(
               from(c in Cursor,
                 where:
                   c.tenant_id == ^tenant_id and c.repo == ^repo and c.change_id == ^change_id,
                 select: c
               ),
               set: [last_pulled_at: now, updated_at: now]
             ) do
          {1, [cursor]} -> cursor
          {0, []} -> nil
        end
      end)

    if cursor, do: {:ok, cursor}, else: {:error, :unknown_change}
  end

  defp live_source(tenant_id, repo) do
    case Intake.chg_source_for_repo(tenant_id, repo) do
      %Source{change_events_secret: secret} = source when is_binary(secret) -> {:ok, source}
      _ -> {:error, :no_chg_source}
    end
  end

  defp page(%{max_pages: max}, applied_seq, pages) when pages >= max,
    do: {:ok, %{applied_seq: applied_seq, pages: pages}}

  defp page(%{source: source, cursor: cursor} = pull_ctx, after_seq, pages) do
    pull_ctx.base_url
    |> pull_ctx.client.events_after(source.change_events_secret, cursor.change_id, after_seq)
    |> after_fetch(pull_ctx, after_seq, pages + 1)
  end

  defp after_fetch({:ok, []}, _pull_ctx, after_seq, pages),
    do: {:ok, %{applied_seq: after_seq, pages: pages}}

  defp after_fetch({:ok, raw}, pull_ctx, after_seq, pages) when is_list(raw) do
    envelopes = for_change(raw, pull_ctx.source, pull_ctx.cursor)

    case Events.ingest_pulled(pull_ctx.source, envelopes, pull_ctx.ingest_opts) do
      {:ok, %{applied_seq: seq}} when is_integer(seq) and seq > after_seq ->
        page(pull_ctx, seq, pages)

      {:ok, _no_progress} ->
        {:ok, %{applied_seq: after_seq, pages: pages}}

      {:error, :unauthorized} ->
        {:error, :source_refused}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp after_fetch({:error, :unauthorized}, pull_ctx, _after_seq, _pages) do
    alert_pull_refused(pull_ctx.source, pull_ctx.cursor)
    {:error, :pull_unauthorized}
  end

  defp after_fetch({:error, reason}, %{source: source, cursor: cursor}, _after_seq, _pages) do
    Logger.warning(
      "change pull failed: source_id=#{source.id} change_id=#{inspect(cursor.change_id)} " <>
        "reason=#{inspect(reason)}"
    )

    {:error, reason}
  end

  # Validated exactly as a push, and held to the change and repository that were asked for:
  # chg-server's answer about some other change is not an answer about this one.
  defp for_change(raw, source, cursor) do
    Enum.flat_map(raw, fn item ->
      with {:ok, envelope} <- Envelope.validate(item),
           true <- envelope.change_id == cursor.change_id,
           true <- String.downcase(envelope.repo) == String.downcase(source.repo_full_name) do
        [envelope]
      else
        _ ->
          Logger.warning(
            "change pull dropped an envelope that is invalid or not about the change asked " <>
              "for: source_id=#{source.id} change_id=#{inspect(cursor.change_id)}"
          )

          []
      end
    end)
  end

  defp alert_pull_refused(%Source{} = source, %Cursor{} = cursor) do
    :telemetry.execute([:loopctl, :changes, :pull_refused], %{count: 1}, %{source: source.id})

    Logger.error(
      "chg-server refused loopctl's signed gap pull (401): tenant_id=#{source.tenant_id} " <>
        "source_id=#{source.id} change_id=#{inspect(cursor.change_id)}. The source's " <>
        "change_events_secret and chg-server's copy disagree; events for this repository " <>
        "are not reaching loopctl."
    )

    # The shared operator-alert contract (`%{alert, metric, value, threshold,
    # window_seconds, at}`), ids only — never the secret or an event body.
    payload = %{
      "alert" => "changes.pull_unauthorized",
      "metric" => "changes.pull_unauthorized",
      "value" => 1,
      "threshold" => 1,
      "window_seconds" => 0,
      "tenant_id" => source.tenant_id,
      "source_id" => source.id,
      "repo" => source.repo_full_name,
      "change_id" => cursor.change_id,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case %{payload: payload} |> ScaleAlertDeliveryWorker.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("change pull: failed to enqueue operator alert: #{inspect(reason)}")
        :ok
    end
  end
end
