defmodule LoopctlWeb.Helpers.Pagination do
  @moduledoc """
  Shared pagination helpers for list endpoints.

  The knowledge enumeration/search endpoints (`GET /articles`,
  `GET /knowledge/search`, `GET /knowledge/drafts`) accept an `offset`/`limit`
  pair and paginate to exhaustion over `meta.total_count`.

  A caller requesting an over-large `limit` is **clamped** to the maximum page
  size, never rejected. The HTTP layer returns the **effective limit** in
  `meta.limit` so the caller can trust it and advance `offset` by that amount
  to paginate to completeness without skipping rows (see #148 A1, where silent
  clamping used to cause row skips).

  This is safe because:
  - The context layer (`Loopctl.Knowledge`) also clamps as a safety net
  - The client has `meta.limit` (the effective page size returned)
  - Offset-based pagination works correctly when advancing by the effective limit
  - Keyset-based pagination (via cursor) is the preferred unbounded path
  """

  alias Loopctl.Knowledge

  @doc """
  Clamps the requested `"limit"` query param to the maximum page size.

  Returns `{:ok, effective_limit}` where `effective_limit` is the
  `min(parsed_limit, max)`. When `limit` is absent or malformed, returns
  `{:ok, default_limit}` where `default_limit` is the context's default
  (typically 20).

  The returned effective limit should be passed to the context layer and
  returned in `meta.limit` so the client can trust it and advance correctly.
  """
  @spec validate_limit(map()) :: {:ok, pos_integer()} | {:error, :bad_request, String.t()}
  def validate_limit(params), do: validate_limit(params, Knowledge.max_page_size())

  @spec validate_limit(map(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, :bad_request, String.t()}
  def validate_limit(params, max) when is_map(params) and is_integer(max) do
    case parse_int(params["limit"]) do
      n when is_integer(n) ->
        {:ok, max(min(n, max), 1)}

      _ ->
        {:ok, 20}
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
