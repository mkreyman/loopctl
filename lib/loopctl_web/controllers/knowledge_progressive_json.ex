defmodule LoopctlWeb.KnowledgeProgressiveJSON do
  @moduledoc """
  JSON rendering for the progressive-disclosure index endpoint (US-31.3/31.4).

  Stubs are compact by design: id/title/category/summary only, never a body — the
  body is fetched on demand via the drill endpoint. `category` is stringified for
  a stable wire shape.
  """

  @doc """
  Renders the HEAT index (#554).

  Distinct from `index/1` because the payloads differ where it matters: a heat stub carries
  `heat` (the windowed body-read count that produced its rank), and the meta carries the DRILL
  INSTRUCTION. The instruction is part of the wire shape on purpose — an index that lists ids
  without saying they are actionable gets read as prose.
  """
  def heat_index(%{results: results, meta: meta}) do
    %{
      data: Enum.map(results, &render_heat_stub/1),
      meta: %{
        top_k: meta.top_k,
        returned: meta.returned,
        unresolved: meta.unresolved,
        truncated: meta.truncated,
        char_budget: meta.char_budget,
        chars: meta.chars,
        heat_window: meta.heat_window,
        counted_access_types: meta.counted_access_types,
        drill: meta.drill
      }
    }
  end

  defp render_heat_stub(stub) do
    %{
      id: stub.id,
      title: stub.title,
      category: stub.category,
      heat: stub.heat,
      summary: stub.summary
    }
  end

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
