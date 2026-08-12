defmodule LoopctlWeb.Helpers.BodyWindow do
  @moduledoc """
  Parses the serialized-body window params (`body_max_bytes` / `body_offset`) shared by
  every endpoint that returns ONE article's full body (#652 item 4).

  Lives here rather than in a controller because the two body paths — `knowledge_get`
  and `knowledge_progressive_drill` — must bound the body identically. A second copy
  drifts, and the path with the stale copy is the one that goes back to returning a
  response no client can accept. That split is exactly what #572 had to undo for read
  accounting.

  Both params are presentation knobs on a READ, so an unparseable value degrades to the
  default rather than 422-ing a knowledge lookup in the middle of an agent's task —
  the same rule `ArticleController.links_mode/1` follows.

  `body_max_bytes: 0` means the WHOLE body (an explicit opt-out of the default budget).
  """

  alias LoopctlWeb.ArticleJSON

  @doc """
  Returns the `{offset, max_bytes}` window for `params`, defaulting to
  `ArticleJSON.article_body_byte_budget/0` from byte 0.
  """
  @spec parse(map()) :: {non_neg_integer(), non_neg_integer()}
  def parse(params) when is_map(params) do
    {non_neg_int(params["body_offset"], 0),
     non_neg_int(params["body_max_bytes"], ArticleJSON.article_body_byte_budget())}
  end

  def parse(_params), do: {0, ArticleJSON.article_body_byte_budget()}

  defp non_neg_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp non_neg_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_value, default), do: default
end
