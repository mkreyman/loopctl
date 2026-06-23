defmodule LoopctlWeb.Helpers.Pagination do
  @moduledoc """
  Shared pagination helpers for list endpoints.

  The knowledge enumeration/search endpoints (`GET /articles`,
  `GET /knowledge/search`, `GET /knowledge/drafts`) accept an `offset`/`limit`
  pair and paginate to exhaustion over `meta.total_count`. A caller advancing
  `offset` by the limit it *requested* must be able to trust that the server
  returned (up to) that many rows — otherwise it silently skips the rows the
  server dropped (see #148 A1, where a `limit=200` request returned 100 rows and
  a by-tag cleanup scanned only half the data).

  To make that contract honest, an over-large `limit` is **rejected with 400**
  rather than silently clamped. The context layer (`Loopctl.Knowledge`) still
  clamps as an internal safety net, but the HTTP layer never returns fewer rows
  than requested without an error.
  """

  alias Loopctl.Knowledge

  @doc """
  Validates the requested `"limit"` query param against the maximum page size.

  Returns `:ok` when `limit` is absent, malformed (treated as absent → server
  default), or within range. Returns `{:error, :bad_request, message}` — the
  shape `LoopctlWeb.FallbackController` renders as a 400 — when a parseable
  integer limit exceeds the cap. Defaults the cap to
  `Loopctl.Knowledge.max_page_size/0`.
  """
  @spec validate_limit(map()) :: :ok | {:error, :bad_request, String.t()}
  def validate_limit(params), do: validate_limit(params, Knowledge.max_page_size())

  @spec validate_limit(map(), pos_integer()) :: :ok | {:error, :bad_request, String.t()}
  def validate_limit(params, max) when is_map(params) and is_integer(max) do
    case parse_int(params["limit"]) do
      n when is_integer(n) and n > max ->
        {:error, :bad_request,
         "limit exceeds the maximum page size of #{max}; " <>
           "request limit <= #{max} and advance offset to paginate to completeness"}

      _ ->
        :ok
    end
  end

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(_), do: nil
end
