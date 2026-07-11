defmodule Loopctl.Knowledge.RetrievalMetrics do
  @moduledoc """
  Retrieval-precision metric (agents' KB #3) — closes the loop on whether retrieval is
  actually improving.

  The signal: of the articles a search SURFACED on a given day, how many did the agent
  then OPEN (a `get`/`context` on the same article, by the same api_key, within a
  follow-through window)? That share is `precision`. It's a mechanical proxy, computed
  purely from `article_access_events` — no LLM, no labels — and it should trend UP as
  dedup (#1), navigation (#5) and conflict resolution (#4) make the corpus cleaner and
  the top results more on-target.

  Honest caveat: it measures search → *open*, not search → *useful*. An agent that uses
  a snippet without opening the article counts as a miss, so the absolute number
  undercounts precision. The bias is consistent, so the TREND is the meaningful thing.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.ArticleAccessEvent
  alias Loopctl.Knowledge.RetrievalMetricSnapshot

  @default_window_seconds 1800

  @doc """
  Compute precision for a single `day` (a `Date`) and follow-through `window_seconds`.

  Returns `%{searched, followed_through, precision, day, window_seconds,
  curated_searched, curated_followed_through, curated_precision, retrieved_searched,
  retrieved_followed_through, retrieved_precision}`.

  The `curated_*`/`retrieved_*` fields (US-31.2, AC-31.2.5) are the SAME
  searched/followed_through/precision computation, restricted to `"search"` events
  whose `metadata->>'mode'` is `"hybrid_curated"` / `"hybrid_retrieved"` (set by
  `Loopctl.Knowledge.hybrid_search/3`) — so the hybrid resolver's provenance decision
  is observable through this NAMED surface, not just via ad-hoc raw
  `article_access_events` queries on the mode tag. Non-hybrid search events (`"keyword"`,
  `"semantic"`, `"combined"`, etc.) contribute to the top-level `searched`/
  `followed_through`/`precision` only, never to either provenance bucket.
  """
  @spec compute(Ecto.UUID.t(), Date.t(), pos_integer()) :: map()
  def compute(tenant_id, %Date{} = day, window_seconds \\ @default_window_seconds) do
    day_start = DateTime.new!(day, ~T[00:00:00.000000], "Etc/UTC")
    day_end = DateTime.add(day_start, 1, :day)

    searched_q =
      from(s in ArticleAccessEvent,
        as: :s,
        where: s.tenant_id == ^tenant_id,
        where: s.access_type == "search",
        where: s.accessed_at >= ^day_start and s.accessed_at < ^day_end
      )

    searched = AdminRepo.aggregate(searched_q, :count, :id)
    followed = compute_followed_through(searched_q, window_seconds)
    precision = safe_precision(followed, searched)

    curated_q = where(searched_q, [s], fragment("?->>'mode' = ?", s.metadata, "hybrid_curated"))
    curated_searched = AdminRepo.aggregate(curated_q, :count, :id)
    curated_followed = compute_followed_through(curated_q, window_seconds)
    curated_precision = safe_precision(curated_followed, curated_searched)

    retrieved_q =
      where(searched_q, [s], fragment("?->>'mode' = ?", s.metadata, "hybrid_retrieved"))

    retrieved_searched = AdminRepo.aggregate(retrieved_q, :count, :id)
    retrieved_followed = compute_followed_through(retrieved_q, window_seconds)
    retrieved_precision = safe_precision(retrieved_followed, retrieved_searched)

    %{
      day: day,
      window_seconds: window_seconds,
      searched: searched,
      followed_through: followed,
      precision: precision,
      curated_searched: curated_searched,
      curated_followed_through: curated_followed,
      curated_precision: curated_precision,
      retrieved_searched: retrieved_searched,
      retrieved_followed_through: retrieved_followed,
      retrieved_precision: retrieved_precision
    }
  end

  # Shared "searched -> followed-through within window" correlated-exists count, reused
  # for the aggregate AND each provenance bucket so the follow-through definition can
  # never drift between the three.
  defp compute_followed_through(searched_q, window_seconds) do
    searched_q
    |> where(
      [s],
      exists(
        from(o in ArticleAccessEvent,
          where:
            o.tenant_id == parent_as(:s).tenant_id and
              o.api_key_id == parent_as(:s).api_key_id and
              o.article_id == parent_as(:s).article_id and
              o.access_type in ["get", "context"] and
              o.accessed_at > parent_as(:s).accessed_at and
              fragment(
                "? <= ? + (? * interval '1 second')",
                o.accessed_at,
                parent_as(:s).accessed_at,
                ^window_seconds
              )
        )
      )
    )
    |> AdminRepo.aggregate(:count, :id)
  end

  defp safe_precision(_followed, 0), do: 0.0
  defp safe_precision(followed, searched), do: followed / searched

  @doc """
  Compute a day's precision and upsert the snapshot (idempotent per tenant/day/window).
  Returns `{:ok, %RetrievalMetricSnapshot{}}`.
  """
  @spec snapshot(Ecto.UUID.t(), Date.t(), pos_integer()) ::
          {:ok, RetrievalMetricSnapshot.t()} | {:error, Ecto.Changeset.t()}
  def snapshot(tenant_id, %Date{} = day, window_seconds \\ @default_window_seconds) do
    m = compute(tenant_id, day, window_seconds)

    attrs = %{
      day: m.day,
      window_seconds: m.window_seconds,
      searched: m.searched,
      followed_through: m.followed_through,
      precision: m.precision,
      curated_searched: m.curated_searched,
      curated_followed_through: m.curated_followed_through,
      curated_precision: m.curated_precision,
      retrieved_searched: m.retrieved_searched,
      retrieved_followed_through: m.retrieved_followed_through,
      retrieved_precision: m.retrieved_precision,
      computed_at: DateTime.utc_now()
    }

    %RetrievalMetricSnapshot{tenant_id: tenant_id}
    |> RetrievalMetricSnapshot.changeset(attrs)
    |> AdminRepo.insert(
      on_conflict:
        {:replace,
         [
           :searched,
           :followed_through,
           :precision,
           :curated_searched,
           :curated_followed_through,
           :curated_precision,
           :retrieved_searched,
           :retrieved_followed_through,
           :retrieved_precision,
           :computed_at,
           :updated_at
         ]},
      conflict_target: [:tenant_id, :day, :window_seconds]
    )
  end

  @doc """
  The precision time series, most recent day first. Opts: `:limit` (default 30),
  `:offset`. Returns `%{data: [snapshot maps], meta: %{limit, offset, total_count}}`.
  """
  @spec list_snapshots(Ecto.UUID.t(), keyword()) :: %{data: [map()], meta: map()}
  def list_snapshots(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 30) |> max(1) |> min(365)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base = from(s in RetrievalMetricSnapshot, where: s.tenant_id == ^tenant_id)
    total_count = AdminRepo.aggregate(base, :count, :id)

    data =
      from(s in base,
        order_by: [desc: s.day, desc: s.window_seconds],
        limit: ^limit,
        offset: ^offset,
        select: %{
          day: s.day,
          window_seconds: s.window_seconds,
          searched: s.searched,
          followed_through: s.followed_through,
          precision: s.precision,
          curated_searched: s.curated_searched,
          curated_followed_through: s.curated_followed_through,
          curated_precision: s.curated_precision,
          retrieved_searched: s.retrieved_searched,
          retrieved_followed_through: s.retrieved_followed_through,
          retrieved_precision: s.retrieved_precision
        }
      )
      |> AdminRepo.all()

    %{data: data, meta: %{limit: limit, offset: offset, total_count: total_count}}
  end
end
