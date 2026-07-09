defmodule Loopctl.Memory do
  @moduledoc """
  Context for the agent-memory subsystem (Epic 28, Part 1).

  Two persistence substrates, kept strictly separate from the Knowledge Wiki:

  - `Loopctl.Memory.SessionMemory` — short-term, append-only, expiring working
    memory (no embedding).
  - `Loopctl.Memory.Memory` — long-term, `vector(1536)`-embedded, HNSW-recalled
    memory.

  This foundation story provides the schemas, migrations, and the pinned
  `subject_id` derivation. The write/list/recall/forget/prune paths are added in
  US-28.2.

  ## `subject_id` — the memory scope owner

  Every memory row is owned by a `subject_id` string resolved SERVER-SIDE from
  the caller's API key — never accepted from request params. See
  `subject_id_for/1`.
  """

  alias Loopctl.Auth.ApiKey

  @doc """
  Resolves the `subject_id` (memory scope owner) from an authenticated API key.

  The derivation is pinned and total:

  - For an **agent-role** key with a non-blank `agent_id`, the subject is the
    `agent_id` — so every ephemeral key an agent rotates through shares one
    memory scope.
  - Otherwise (user/orchestrator/superadmin keys, or an agent key without an
    `agent_id`), the subject is the API key's own `id`.

  Because `agent` is the FLOOR role and every authenticated key has a binary_id
  `id`, resolution always yields a non-null, non-blank subject for a real key —
  the `{:error, :subject_id_unresolvable}` path exists only to make the failure
  explicit rather than persist a null-scoped (leak-prone) row.

  ## Examples

      iex> Loopctl.Memory.subject_id_for(%Loopctl.Auth.ApiKey{role: :agent, agent_id: "agent-123", id: "key-1"})
      {:ok, "agent-123"}

      iex> Loopctl.Memory.subject_id_for(%Loopctl.Auth.ApiKey{role: :user, agent_id: nil, id: "key-1"})
      {:ok, "key-1"}
  """
  @spec subject_id_for(ApiKey.t()) :: {:ok, String.t()} | {:error, :subject_id_unresolvable}
  def subject_id_for(%ApiKey{role: :agent, agent_id: agent_id})
      when is_binary(agent_id) and agent_id != "" do
    {:ok, to_string(agent_id)}
  end

  def subject_id_for(%ApiKey{id: id}) when is_binary(id) and id != "" do
    {:ok, to_string(id)}
  end

  def subject_id_for(_), do: {:error, :subject_id_unresolvable}
end
