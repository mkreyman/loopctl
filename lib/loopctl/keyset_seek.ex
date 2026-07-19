defmodule Loopctl.KeysetSeek do
  @moduledoc """
  Shared keyset SEEK builder for `(inserted_at, id)` row-value pagination
  (US-27.9a / US-27.9b).

  Every keyset enumeration (`Loopctl.Knowledge` article list + index, `Loopctl.Audit`
  change feed, `Loopctl.Knowledge.StreamingExport`) seeks PAST a cursor position with
  the SAME row-value comparison. Centralizing it here keeps the load-bearing `type/2`
  annotations in ONE place: a raw `fragment` row-value comparison would otherwise send
  `id` as text and `inserted_at` without the column's type, which Postgrex rejects
  (`id` is `binary_id` / uuid). The `type(^bound, a.field)` calls tell Ecto the bound
  params' DB types so the composite `(tenant_id, inserted_at, id)` btree serves the
  seek directly.

  The query's binding must expose `inserted_at` and `id` on its FIRST positional
  binding (`[a]`) for `after_position/2`, or `inserted_at` and `seq` for
  `before_position/2` — every caller's base query is `from(a in Schema, ...)`, so
  this holds.
  """

  import Ecto.Query

  @doc """
  Adds the keyset seek `WHERE (inserted_at, id) > (^cursor_inserted_at, ^cursor_id)`
  to `query` for the given `(inserted_at, id)` cursor position. With `nil` (no
  cursor), returns the query unchanged (enumerate from the start).
  """
  @spec after_position(Ecto.Query.t(), {DateTime.t(), Ecto.UUID.t()} | nil) :: Ecto.Query.t()
  def after_position(query, nil), do: query

  def after_position(query, {%DateTime{} = inserted_at, id}) when is_binary(id) do
    where(
      query,
      [a],
      fragment(
        "(?, ?) > (?, ?)",
        a.inserted_at,
        a.id,
        type(^inserted_at, a.inserted_at),
        type(^id, a.id)
      )
    )
  end

  @doc """
  Adds the DESC (newest-first) keyset seek
  `WHERE (inserted_at, seq) < (^cursor_inserted_at, ^cursor_seq)` to `query`
  (US-40.C2). Unlike `after_position/2` (ASC on `(inserted_at, id)`), this walks
  history OLDER than the cursor and tie-breaks on `seq` — a monotonic bigint column
  (e.g. `channel_posts.seq` bigserial), NOT a random v4 UUID — so the ordering is
  deterministic. The `type(^seq, a.seq)` annotation sends the bound as a bigint so
  the composite `(tenant_id, project_id, inserted_at DESC, seq DESC)` btree serves
  the seek directly. With `nil` (no cursor), returns the query unchanged (start from
  the newest row).
  """
  @spec before_position(Ecto.Query.t(), {DateTime.t(), integer()} | nil) :: Ecto.Query.t()
  def before_position(query, nil), do: query

  def before_position(query, {%DateTime{} = inserted_at, seq}) when is_integer(seq) do
    where(
      query,
      [a],
      fragment(
        "(?, ?) < (?, ?)",
        a.inserted_at,
        a.seq,
        type(^inserted_at, a.inserted_at),
        type(^seq, a.seq)
      )
    )
  end
end
