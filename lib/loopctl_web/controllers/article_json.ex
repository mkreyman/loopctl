defmodule LoopctlWeb.ArticleJSON do
  @moduledoc """
  JSON rendering helpers for article API responses.

  Provides consistent serialization for articles and article links
  across all article controller actions.

  ## `idempotency_key` is accepted, never echoed

  An article's `idempotency_key` is a WRITE-side capture identity: a caller supplies its
  own, and `GET /api/v1/articles?idempotency_key=…` answers "have I already captured
  this?" from the caller's own key. Serializing the stored value did something different —
  it ENUMERATED the capture identities of every article a reader merely has read access
  to, in bulk, unprompted. It is therefore no longer rendered in any article payload.

  What this does NOT claim is secrecy for the key. The FILTER is deliberately kept — it is
  the "have I already captured this?" check — and it is an EXACT match on a key the caller
  must already hold or guess, answered only by articles the caller can read in full
  (visibility scoping applies to the filter exactly as to any other list query, so another
  agent's `private`/`owner` article never answers). What remains is therefore bounded to
  "an article you can already read also tells you its capture key", not an enumeration and
  not a probe of anything you cannot see. Nothing should be built as if the key were a
  secret, and nothing needs to be.
  """

  @doc """
  Renders a list of articles with pagination meta.

  When `meta.include_body` is true the full `body` is included per row (the
  response is byte-budget bounded server-side); otherwise each row is a body-less
  summary so large enumeration pages stay small.
  """
  def index(%{articles: articles, meta: meta}) do
    renderer =
      if Map.get(meta, :include_body, false), do: &article_data/1, else: &article_summary/1

    %{data: Enum.map(articles, renderer), meta: meta}
  end

  @doc """
  Renders a single article with preloaded links.

  `links` selects how much of the link graph to serialize — `:full` (default, back
  compatible), `:count`, or `:none`. See `article_data_with_links/2`.

  `body_window` bounds the serialized `body` — see `apply_body_window/2`.
  """
  def show(%{article: article} = assigns) do
    data =
      article
      |> article_data_with_links(Map.get(assigns, :links, :full))
      |> apply_body_window(Map.get(assigns, :body_window, default_body_window()))

    %{data: data}
  end

  # Default serialized-body window for a single-article read (#538, #652 item 4).
  #
  # #538 trimmed the LINK half of this response and capped both arrays. What it did not
  # bound is the body, and that is what is left: four measured `knowledge_get` results of
  # 61-82KB were rejected CLIENT-side by the harness token cap, so the article was found
  # and the read discarded whole. A truncated body carrying its own continuation offset
  # is strictly better than nothing, which is what those four reads got.
  #
  # 32KB is ~8k tokens — comfortably under the cap that rejected 61KB, and far above the
  # ~3KB median article, so the overwhelming majority of reads are byte-identical to
  # before. Config-overridable so ops can tune it and tests can exercise truncation
  # cheaply. `body_max_bytes: 0` on the request opts out entirely.
  @article_body_byte_budget 32_000

  @doc "Default single-article body byte budget. Read by the OpenAPI spec so the two cannot drift."
  def article_body_byte_budget,
    do: Application.get_env(:loopctl, :article_body_byte_budget, @article_body_byte_budget)

  defp default_body_window, do: {0, article_body_byte_budget()}

  @doc """
  Bounds the serialized `body` to a byte window and reports what was withheld.

  `window` is `{offset, max_bytes}`; `max_bytes` of `0` (or a `nil` body) means the whole
  body, unbounded. The reported byte counts are of the RAW body, so a caller paginating
  with `next_body_offset` walks the same coordinate space the counts describe.

  Slicing is UTF-8 safe: a window that would land mid-codepoint is shortened to the last
  whole character, never emitting invalid UTF-8 (which `Jason` would refuse to encode,
  turning a large read into a 500).

  Fields added whenever a body is present:

    * `body_bytes` — the FULL body size, so the caller can size the remaining fetches
    * `body_offset` / `body_returned_bytes` — the window actually served
    * `body_truncated` — whether anything past this window was withheld
    * `next_body_offset` — where to continue, or `nil` at the end

  These are always present, including on an untruncated read: a caller must be able to
  tell "this is the whole body" from "this is all I asked for" without a second request.
  """
  @spec apply_body_window(map(), {non_neg_integer(), non_neg_integer()}) :: map()
  def apply_body_window(%{body: body} = data, _window) when not is_binary(body), do: data

  def apply_body_window(%{body: body} = data, {offset, max_bytes}) do
    total = byte_size(body)
    offset = body |> advance_to_boundary(min(max(offset, 0), total))
    remaining = total - offset
    take = if max_bytes <= 0, do: remaining, else: min(max_bytes, remaining)

    slice = body |> binary_part(offset, take) |> trim_trailing_partial()
    returned = byte_size(slice)
    next = offset + returned

    data
    |> Map.put(:body, slice)
    |> Map.put(:body_bytes, total)
    |> Map.put(:body_offset, offset)
    |> Map.put(:body_returned_bytes, returned)
    |> Map.put(:body_truncated, next < total)
    |> Map.put(:next_body_offset, if(next < total, do: next, else: nil))
  end

  def apply_body_window(data, _window), do: data

  # A caller-supplied offset can land mid-codepoint (it is a byte count, and the caller
  # may have invented it). Move FORWARD to the next character boundary rather than
  # emitting a leading partial byte — the result would not be valid UTF-8, and Jason
  # refuses to encode that, turning a large read into a 500.
  defp advance_to_boundary(body, offset) do
    case body do
      <<_::binary-size(^offset), byte, _::binary>> when byte >= 0x80 and byte < 0xC0 ->
        advance_to_boundary(body, offset + 1)

      _ ->
        offset
    end
  end

  # Shrink the window (never grow it) until it ENDS on a codepoint boundary. At most 3
  # bytes are ever dropped, since that is the longest partial UTF-8 sequence.
  defp trim_trailing_partial(slice) do
    if slice == "" or String.valid?(slice) do
      slice
    else
      trim_trailing_partial(binary_part(slice, 0, byte_size(slice) - 1))
    end
  end

  @doc "Renders a newly created article."
  def create(%{article: article}), do: %{data: article_data(article)}

  @doc "Renders an updated article."
  def update(%{article: article}), do: %{data: article_data(article)}

  @doc "Renders an archived article."
  def delete(%{article: article}), do: %{data: article_data(article)}

  @doc "Serializes core article fields WITHOUT the body (body-less enumeration summary)."
  def article_summary(article) do
    %{
      id: article.id,
      tenant_id: article.tenant_id,
      project_id: article.project_id,
      title: article.title,
      category: article.category,
      status: article.status,
      tags: article.tags,
      source_type: article.source_type,
      source_id: article.source_id,
      metadata: article.metadata,
      inserted_at: article.inserted_at,
      updated_at: article.updated_at
    }
  end

  @doc "Serializes core article fields (no links)."
  def article_data(article) do
    %{
      id: article.id,
      tenant_id: article.tenant_id,
      project_id: article.project_id,
      title: article.title,
      # The undo record for the nightly consolidation retitle, and the reason it is on the
      # FULL read and not on `article_summary/1`: a durable record nobody can read is not an
      # undo. `null` on every article no machine has retitled — which is nearly all of them,
      # so the enumeration path does not pay for it.
      previous_title: article.previous_title,
      # The reversible retrieval tombstone, on the FULL read for the same reason
      # `previous_title` is: a suppression nobody can read is not inspectable, and the by-id
      # read is deliberately the ONE surface a suppressed article still answers on. All three
      # are `null` on every article nobody has suppressed, which is nearly all of them, so
      # the enumeration path does not pay for them.
      suppressed_at: article.suppressed_at,
      suppressed_by: article.suppressed_by,
      suppression_reason: article.suppression_reason,
      body: article.body,
      category: article.category,
      status: article.status,
      tags: article.tags,
      source_type: article.source_type,
      source_id: article.source_id,
      metadata: article.metadata,
      inserted_at: article.inserted_at,
      updated_at: article.updated_at
    }
  end

  # Ranked links returned per direction under `:full` (#538). Agents are instructed to
  # open every search hit with `knowledge_get`, so this response is paid on essentially
  # every wiki read in every session — a hub article's 38 links cost ~4k tokens to read
  # 735 tokens of body. Past a couple of dozen ranked neighbours an agent follows none of
  # them anyway, so the tail is pure cost. `links_total` still reports the true size, and
  # `knowledge_graph` remains the tool for actual traversal.
  @max_links_per_direction 25

  # Same budget for the conflict list — an INCOMING conflict edge is added by every
  # newly-ingested near-duplicate, so it is unbounded across a corpus.
  @max_conflicts @max_links_per_direction

  @doc "The per-direction link cap enforced by `:full`. Read by the OpenAPI spec so the two cannot drift."
  def max_links_per_direction, do: @max_links_per_direction

  @doc "The `potential_conflicts` cap, enforced in every mode. Read by the OpenAPI spec so the two cannot drift."
  def max_conflicts, do: @max_conflicts

  @doc """
  Serializes an article with its link graph, at one of three levels of detail.

    * `:full` (default) — both direction arrays, ranked and capped at
      `#{@max_links_per_direction}` per direction.
    * `:count` — no arrays, just `links_total` and `links_truncated`. Enough to decide
      whether a second `:full` fetch is worth it, at a fixed handful of bytes — which
      needs to include whether the cap will bite, or the caller learns that only by
      paying for the fetch.
    * `:none` — no link fields at all.

  `potential_conflicts` is present in ALL THREE modes — it is the one part of the link
  graph callers are told to act on rather than browse (an unresolved "too similar to
  coexist" pair), so dropping it with the bulk links would quietly turn off conflict
  discovery for anyone opting into a cheaper read. It is capped at `#{@max_conflicts}`
  (highest similarity first) with `conflicts_total` / `conflicts_truncated`, so a cheap
  mode stays cheap on a conflict-heavy hub.

  ## Why each link carries only its FAR side

  A link object used to embed both `source_article` and `target_article`. For an outgoing
  link the source is always the article you asked for; for an incoming link, the target
  is. That near side is a constant echo of the id in the request URL, and — since
  `Loopctl.Knowledge` preloads only the far side — its title is ALWAYS `nil`. It was 14%
  of a typical response and carried nothing. Direction is already unambiguous from which
  array the link is in.
  """
  def article_data_with_links(article, links \\ :full)

  def article_data_with_links(article, :none) do
    article_data(article)
    |> put_conflicts(article)
  end

  def article_data_with_links(article, :count) do
    outgoing = loaded_links(article.outgoing_links)
    incoming = loaded_links(article.incoming_links)

    article_data(article)
    |> Map.put(:links_total, length(outgoing) + length(incoming))
    |> Map.put(:links_truncated, over_cap?(outgoing) or over_cap?(incoming))
    |> put_conflicts(article)
  end

  def article_data_with_links(article, :full) do
    outgoing = loaded_links(article.outgoing_links)
    incoming = loaded_links(article.incoming_links)
    total = length(outgoing) + length(incoming)

    ranked_out = rank_and_cap(outgoing)
    ranked_in = rank_and_cap(incoming)
    returned = length(ranked_out) + length(ranked_in)

    article_data(article)
    |> Map.put(
      :outgoing_links,
      Enum.map(ranked_out, &link_data(&1, &1.target_article_id, &1.target_article))
    )
    |> Map.put(
      :incoming_links,
      Enum.map(ranked_in, &link_data(&1, &1.source_article_id, &1.source_article))
    )
    |> Map.put(:links_total, total)
    |> Map.put(:links_truncated, returned < total)
    |> put_conflicts(article)
  end

  defp over_cap?(links), do: length(links) > @max_links_per_direction

  # An open `:potential_conflict` outranks everything — it is the one link type the
  # caller is asked to ACT on. Within a type, the auto-linker's `similarity_score` orders
  # the rest. Only the system writers ever record one: `Knowledge.create_link/3` strips
  # `similarity_score` from caller metadata (kb-02 provenance), so on a hand-created or
  # OKF-imported corpus EVERY link ties at 0.0 and the score decides nothing. Those fall
  # back to oldest-first, which retains the neighbourhood a curator established earliest
  # rather than an arbitrary UUID order; `id` breaks the remaining ties so the result is
  # stable across identical requests.
  defp rank_and_cap(links) do
    links
    |> Enum.sort_by(fn link ->
      {if(link.relationship_type == :potential_conflict, do: 0, else: 1),
       -(link_similarity(link) || 0.0), DateTime.to_unix(link.inserted_at, :microsecond), link.id}
    end)
    |> Enum.take(@max_links_per_direction)
  end

  # The link arrays are capped per direction; this one is capped on its own budget, in
  # every mode, because `:none`/`:count` exist to make the read CHEAP and an uncapped
  # array of incoming conflict edges would defeat exactly that on the hub articles the
  # cap was introduced for. Strongest similarity first, so what survives is the pair most
  # worth merging — then the SAME tie-break as `rank_and_cap/1`, because an unscored
  # (hand-created or imported) conflict set ties at 0.0 and would otherwise be cut by an
  # arbitrary peer-UUID order. Sorting the links, not the rendered peers, is what keeps
  # `inserted_at` reachable here.
  defp put_conflicts(data, article) do
    all = conflict_links(article)

    kept =
      all
      |> Enum.sort_by(fn {link, _peer, peer_id} ->
        # ASSERTED conflicts (#730) lead, matching `Knowledge.list_potential_conflicts/2`'s
        # ordering. They carry no similarity score — nothing measured them — so ranking on
        # `similarity || 0.0` alone sorted every assertion BEHIND every system flag and
        # then truncated it out at `@max_conflicts`. That silently deleted the one thing an
        # assertion exists to do: signal "this article is contested" to a reader who never
        # opens the conflict queue. A caller deliberately contesting a pair is a stronger
        # signal than the mechanical 0.93 threshold that produced most of this list.
        {if(asserted_conflict?(link), do: 0, else: 1), -(link_similarity(link) || 0.0),
         DateTime.to_unix(link.inserted_at, :microsecond), peer_id}
      end)
      |> Enum.take(@max_conflicts)
      |> Enum.map(fn {link, peer, peer_id} -> conflict_peer(link, peer, peer_id) end)

    data
    |> Map.put(:potential_conflicts, kept)
    |> Map.put(:conflicts_total, length(all))
    |> Map.put(:conflicts_truncated, length(kept) < length(all))
  end

  # Route-the-findings (#4): the article's `:potential_conflict` links (in either
  # direction) paired with the PEER end, ready to rank and then render. Empty list when
  # none. A conflict that fits under the
  # per-direction cap also appears in incoming/outgoing_links, but past that cap this is
  # the ONLY place it is surfaced — so an agent reading the article still trips over
  # "too similar to coexist" pairs and can merge the redundancy or reconcile.
  defp conflict_links(article) do
    out =
      article.outgoing_links
      |> loaded_links()
      |> Enum.filter(&(&1.relationship_type == :potential_conflict))
      |> Enum.map(&{&1, &1.target_article, &1.target_article_id})

    inc =
      article.incoming_links
      |> loaded_links()
      |> Enum.filter(&(&1.relationship_type == :potential_conflict))
      |> Enum.map(&{&1, &1.source_article, &1.source_article_id})

    out ++ inc
  end

  # Same guarded accessor AND same key-presence contract as `link_data/3`: an unscored
  # link omits `similarity` in both places, so a caller branching on key presence cannot
  # get two answers about the same link inside one response.
  defp conflict_peer(link, peer_article, peer_id) do
    base =
      %{article_id: peer_id, title: loaded_title(peer_article)}
      |> Map.put(:origin, if(asserted_conflict?(link), do: "asserted", else: "system"))
      |> put_assertion_claim(link)

    case link_similarity(link) do
      nil -> base
      score -> Map.put(base, :similarity, score)
    end
  end

  # An assertion's argument travels WITH it. Without this a reader sees an unexplained,
  # unscored conflict and has no way to tell it from a stray link — the prose "SUPERSEDED"
  # banner problem #730 exists to replace, reintroduced one layer out. `evidence` is
  # required at write time, so it is present on every asserted link.
  defp put_assertion_claim(base, link) do
    if asserted_conflict?(link) do
      metadata = link.metadata || %{}

      Map.put(base, :assertion, %{
        classification: metadata["classification"],
        evidence: metadata["evidence"],
        asserted_at: metadata["asserted_at"]
      })
    else
      base
    end
  end

  defp asserted_conflict?(%{metadata: metadata}) when is_map(metadata),
    do: metadata["asserted"] == true

  defp asserted_conflict?(_link), do: false

  # `far_id`/`far_article` are the OTHER end of the link — the target for an outgoing
  # link, the source for an incoming one. `similarity` is the auto-linker's recorded
  # score (absent on a hand-created link), surfaced so a caller can rank or threshold
  # the list instead of treating 38 equally-weighted `relates_to` edges as a flat set.
  defp link_data(link, far_id, far_article) do
    base = %{
      id: link.id,
      relationship_type: link.relationship_type,
      article: %{id: far_id, title: loaded_title(far_article)}
    }

    case link_similarity(link) do
      nil -> base
      score -> Map.put(base, :similarity, score)
    end
  end

  defp link_similarity(link) do
    case get_in(link.metadata || %{}, ["similarity_score"]) do
      score when is_number(score) -> score
      _ -> nil
    end
  end

  defp loaded_links(%Ecto.Association.NotLoaded{}), do: []
  defp loaded_links(nil), do: []
  defp loaded_links(links) when is_list(links), do: links

  defp loaded_title(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded_title(nil), do: nil
  defp loaded_title(article), do: article.title
end
