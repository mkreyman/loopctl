defmodule Loopctl.Memory.PromotionPrefixSupersedeTest do
  @moduledoc """
  A PREFIX-embedded promoted memory may not be SUPERSEDED on cosine alone (#617 round 2).

  `nearest_live/2` refuses to LOOK UP a near-dup on a truncated candidate vector, because
  the 0.92 compare is licensed only by both sides covering the same extent of text. The
  same compare runs from the other side when the STORED row is the prefix — and there it
  retires the longer, more informative memory.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings.ShrinkLadder
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema

  defp candidate(text),
    do: %{text: text, when_to_apply: "", tags: [], confidence: 0.9, cross_links: []}

  defp promoted(scope) do
    from(m in MemorySchema,
      where:
        m.tenant_id == ^scope.tenant_id and m.subject_id == ^scope.subject_id and
          m.source == :promoted,
      order_by: [asc: m.inserted_at]
    )
    |> AdminRepo.all()
  end

  defp mark_prefix_embedded!(memory) do
    memory
    |> Ecto.Changeset.change(%{
      embedding_content_hash: ShrinkLadder.truncated_hash(memory.embedding_content_hash)
    })
    |> AdminRepo.update!()
  end

  setup do
    scope = %{fixture(:memory_scope, subject_id: "A") | session_id: "s1"}
    # The default embedding stub is deterministic per tenant, so any two promoted rows
    # score 1.0 against each other — the near-dup path fires unless something blocks it.
    {:ok, _} = Memory.persist_promotion(scope, [candidate("the first durable fact")])
    [first] = promoted(scope)
    %{scope: scope, first: first}
  end

  test "a WHOLE-text promoted row is superseded, as designed", %{scope: scope, first: first} do
    assert {:ok, %{superseded: 1}} =
             Memory.persist_promotion(scope, [candidate("a second durable fact")])

    refute is_nil(AdminRepo.get!(MemorySchema, first.id).superseded_by)
  end

  test "a PREFIX-embedded promoted row is left alone", %{scope: scope, first: first} do
    mark_prefix_embedded!(first)

    assert {:ok, %{promoted: 1, superseded: 0}} =
             Memory.persist_promotion(scope, [candidate("a second durable fact")])

    assert is_nil(AdminRepo.get!(MemorySchema, first.id).superseded_by)
  end

  test "the mark does not break exact dedupe of the same text", %{scope: scope, first: first} do
    # The hash still identifies the FULL text; only the vector beside it is partial. If the
    # mark were treated as a different hash, the identical candidate would be re-promoted.
    mark_prefix_embedded!(first)

    assert {:ok, %{deduped: 1, promoted: 0}} =
             Memory.persist_promotion(scope, [candidate("the first durable fact")])

    assert length(promoted(scope)) == 1
  end
end
