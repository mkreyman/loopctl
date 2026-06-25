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
  binding (`[a]`) — every caller's base query is `from(a in Schema, ...)`, so this
  holds.
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
end
