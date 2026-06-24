defmodule LoopctlWeb.Helpers.TagMatch do
  @moduledoc """
  Parses the `match` query param for tag filtering.

  `tags` filtering defaults to OR semantics (an article matching ANY of the
  listed tags). `match=all` switches to AND semantics (an article carrying EVERY
  listed tag — e.g. "book hubs" = `tags=book,hub&match=all`). `match=any` is the
  explicit default. An unknown value is a 400 rather than a silent fallback.
  """

  @doc """
  Returns `{:ok, :any | :all}` for a valid (or absent) `match`, or
  `{:error, :bad_request, message}` — the shape `LoopctlWeb.FallbackController`
  renders as a 400 — for an unknown value.
  """
  @spec parse(map()) :: {:ok, :any | :all} | {:error, :bad_request, String.t()}
  def parse(params) when is_map(params) do
    case params["match"] do
      nil -> {:ok, :any}
      "" -> {:ok, :any}
      "any" -> {:ok, :any}
      "all" -> {:ok, :all}
      _other -> {:error, :bad_request, "Invalid match. Allowed values: any, all."}
    end
  end
end
