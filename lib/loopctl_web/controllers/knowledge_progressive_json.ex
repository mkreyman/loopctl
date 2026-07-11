defmodule LoopctlWeb.KnowledgeProgressiveJSON do
  @moduledoc """
  JSON rendering for the progressive-disclosure index endpoint (US-31.3/31.4).

  Stubs are compact by design: id/title/category/summary only, never a body — the
  body is fetched on demand via the drill endpoint. `category` is stringified for
  a stable wire shape.
  """

  @doc "Renders the capped index stubs plus its meta (top_k/candidate_count/truncated)."
  def index(%{stubs: stubs, meta: meta}) do
    %{
      data: Enum.map(stubs, &render_stub/1),
      meta: %{
        top_k: meta.top_k,
        candidate_count: meta.candidate_count,
        truncated: meta.truncated
      }
    }
  end

  defp render_stub(stub) do
    %{
      id: stub.id,
      title: stub.title,
      category: to_string(stub.category),
      summary: stub.summary
    }
  end
end
