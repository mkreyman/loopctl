defmodule Loopctl.Coordination.RefsList do
  @moduledoc """
  Custom `Ecto.Type` for `channel_posts.refs`: a bounded, typed-OPEN LIST of
  reference items `[%{"type" => string, "value" => string, "label" => string?}]`.

  ## Why a custom type (US-40.A1)

  `refs` was a FIXED-KEY map (`field :refs, :map`, allowlist `~w(file pr branch
  commit)`). A map holds one value per key, so it cannot express a real handoff
  pointing at many issues / many `file:line` pairs / several commits. The list
  form does, with a FREE `type` (no allowlist) but an explicit item-count cap
  (enforced in `ChannelPost.validate_refs/1`).

  The list is stored in the EXISTING SCALAR `jsonb` column: `type/0` returns
  `:map`, so Ecto/Postgrex encode the top-level JSON ARRAY into the same `jsonb`
  column the fixed-key map used — no column-type change (a `{:array, :map}` field
  would instead map to a Postgres `jsonb[]` ARRAY column and mismatch the scalar
  `jsonb` column). A DATA migration reshapes any existing stored maps.

  ## Leniency contract

  `cast/1` is deliberately LENIENT: it admits ANY list (normalising each map
  item's keys to strings) so the changeset's `validate_refs/1` runs the deep
  checks — per-item shape, byte-length caps, item-count cap, NUL bytes, secret
  denylist — and surfaces SPECIFIC accumulated 422 errors rather than a single
  opaque cast error (AC-40.A1.4). `cast/1` rejects only a non-list, non-nil scalar
  so a bad scalar/map can never 500 downstream. `load/1`/`dump/1` round-trip the
  list unchanged (already string-keyed maps from `jsonb`), which keeps the keyed-
  slot `on_conflict` upsert (`Loopctl.Coordination`) correct.

  ## Load fail-soft (AC-40.A1.5 — no live row breaks)

  Before US-40.A1 `refs` was a fixed-key MAP, and an empty `%{}` was a valid,
  persistable value. `load/1` therefore coerces a stored JSON OBJECT into the list
  form (`%{}` → `[]`, `{file, pr}` → `[{file}, {pr}]`, key-sorted to mirror the
  data migration) instead of raising. This is defense-in-depth: the
  `ReshapeChannelPostsRefsToList` data migration reshapes every object row, but a
  single legacy row that escaped it (a replica lag, a manual write) must not 500
  the whole channel read — one un-loadable row would deny the coordination bus.

  For completeness the SAME invariant covers an UNEXPECTED stored jsonb SCALAR
  (string/number/boolean) — a shape neither the old fixed-key map schema nor `up/0`
  could ever persist, reachable only via corruption or a manual write. Rather than
  raise an `Ecto` load error and 500 the channel read, `load/1` coerces it to `nil`
  (an empty ref set) and logs a warning so the corrupt row is surfaced, not
  silently hidden. Any loadable value is thus one no un-loadable row can deny.
  """
  use Ecto.Type

  require Logger

  @impl true
  def type, do: :map

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(list) when is_list(list), do: {:ok, Enum.map(list, &normalize_item/1)}
  def cast(_), do: :error

  @impl true
  def load(nil), do: {:ok, nil}
  def load(list) when is_list(list), do: {:ok, list}
  # Coerce a legacy fixed-key MAP (pre-US-40.A1 shape, incl. an empty `%{}`) into
  # the list form rather than raising — see "Legacy-map load coercion" above. Keys
  # are sorted so the item order matches the data migration's `ORDER BY key`; each
  # value is kept as-is (old-shape values were always strings).
  def load(map) when is_map(map) and not is_struct(map) do
    list =
      map
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map(fn {k, v} -> %{"type" => to_string(k), "value" => v} end)

    {:ok, list}
  end

  # Fail-soft on an unexpected stored jsonb SCALAR (string/number/boolean) — a shape
  # neither the old map schema nor `up/0` could persist, only reachable via
  # corruption/manual write. Coerce to `nil` (empty ref set) instead of raising a
  # load error that would 500 the channel read; log so the corrupt row is surfaced.
  def load(other) do
    Logger.warning(
      "RefsList.load/1 coercing unexpected stored refs value to nil: #{inspect(other)}"
    )

    {:ok, nil}
  end

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(list) when is_list(list), do: {:ok, list}
  def dump(_), do: :error

  # Normalise a map item's keys to strings so `validate_refs/1`, the secret scan,
  # and the JSON response see a uniform string-keyed shape regardless of whether
  # the caller sent string or atom keys. A non-map item is passed through untouched
  # for `validate_refs/1` to reject with a specific 422 (never swallowed here).
  defp normalize_item(item) when is_map(item) and not is_struct(item) do
    Map.new(item, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_item(item), do: item
end
