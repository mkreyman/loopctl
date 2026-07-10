defmodule LoopctlWeb.MemoryJSON do
  @moduledoc """
  JSON rendering for the Agent Memory HTTP API (US-28.3).

  Serializes both memory tiers:

  - `Loopctl.Memory.Memory` — long-term, semantically-recalled memory. The raw
    `embedding` vector (`load_in_query: false`) is NEVER rendered.
  - `Loopctl.Memory.SessionMemory` — short-term, chronological working memory.

  All read paths return the pinned envelope from `Loopctl.Memory`:

  - `recall/1` — `%{data: [%{memory, score}], meta: %{total_count, fallback,
    reason, underfilled}}`. `score` is `null` on the ILIKE fallback path.
  - `index/1` — `%{data: [memory], meta: %{total_count, limit, offset}}`.
  """

  alias Loopctl.Memory.Memory
  alias Loopctl.Memory.SessionMemory

  @doc "Renders a single (newly written) memory."
  def show(%{memory: memory}), do: %{data: memory_data(memory)}

  @doc "Renders a paginated list of memories with `meta.total_count/limit/offset`."
  def index(%{results: results, meta: meta}) do
    %{data: Enum.map(results, &memory_data/1), meta: meta}
  end

  @doc """
  Renders a recall result: each entry pairs the memory with its similarity
  `score` (`null` on the fallback path), preserving `meta.fallback/reason/
  underfilled` from the context faithfully (no silent hard cap).
  """
  def recall(%{results: results, meta: meta}) do
    %{data: Enum.map(results, &recall_entry/1), meta: meta}
  end

  defp recall_entry({memory, score}), do: %{memory: memory_data(memory), score: score}

  @doc "Serializes a long-term memory (no embedding) or a session memory."
  def memory_data(%Memory{} = m) do
    %{
      id: m.id,
      tier: "long_term",
      tenant_id: m.tenant_id,
      subject_id: m.subject_id,
      project_id: m.project_id,
      text: m.text,
      confidence: m.confidence,
      source: m.source,
      source_session_id: m.source_session_id,
      tags: m.tags,
      metadata: m.metadata,
      superseded_by: m.superseded_by,
      inserted_at: m.inserted_at,
      updated_at: m.updated_at
    }
  end

  def memory_data(%SessionMemory{} = s) do
    %{
      id: s.id,
      tier: "session",
      tenant_id: s.tenant_id,
      subject_id: s.subject_id,
      project_id: s.project_id,
      session_id: s.session_id,
      role: s.role,
      content: s.content,
      metadata: s.metadata,
      expires_at: s.expires_at,
      seq: s.seq,
      inserted_at: s.inserted_at
    }
  end
end
