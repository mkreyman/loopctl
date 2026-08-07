defmodule Loopctl.Knowledge.ProposalGateTruncationTest do
  @moduledoc """
  What the gate may conclude from a PREFIX vector (#617 round 2).

  The shrink ladder can only embed an over-long proposal as its opening. Scored against
  corpus vectors built from whole texts, a shared opening reads as a near-identity of a
  document the proposal may differ from entirely after the cut.
  """

  use Loopctl.DataCase, async: true

  import Mox

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ProposalGate

  @dims 1536
  @too_long {:error, {:api_error, 400, :context_length_exceeded}}

  defp e(prefix), do: prefix ++ List.duplicate(0.0, @dims - length(prefix))

  # Rejects anything above `limit` bytes, exactly as the provider does, so the gate walks
  # the real ladder rather than being handed a `:truncated` tag by the test.
  defp provider(limit, vector) do
    stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, text ->
      if byte_size(text) > limit, do: @too_long, else: {:ok, vector}
    end)
  end

  setup do
    tenant = fixture(:tenant)
    existing = fixture(:article, %{tenant_id: tenant.id, title: "Changelog", status: :published})
    {:ok, _} = Knowledge.update_embedding(tenant.id, existing.id, e([1.0]))
    %{tenant: tenant, existing: existing}
  end

  test "a proposal judged on a prefix is NEVER assessed below :novel", %{tenant: tenant} do
    # An identical vector would be `:duplicate`. `:duplicate` makes `gate_proposal/4`
    # return `created: false`, and `:low_novelty` drops the write outright for the
    # unattended callers running `on_low_novelty: :skip` — so neither band is a safe cap
    # and the verdict has to clear both. The neighbours still ride the assessment.
    provider(20_000, e([1.0]))

    assessment =
      ProposalGate.assess(tenant.id, %{
        "title" => "Changelog",
        "body" => String.duplicate("x", 50_000)
      })

    assert assessment.verdict == :novel
    assert assessment.score >= 0.97
    assert [_ | _] = assessment.neighbors
  end

  test "a proposal that fits is judged normally", %{tenant: tenant} do
    # The cap must key on an ACTUAL truncation: if it fired on length alone the gate would
    # stop deduplicating every long-but-acceptable article.
    provider(200_000, e([1.0]))

    assessment = ProposalGate.assess(tenant.id, %{"title" => "Changelog", "body" => "short"})

    assert assessment.verdict == :duplicate
  end

  test "the synchronous ladder reaches the byte floor for multi-byte text", %{tenant: tenant} do
    # `build_text/1` caps at 32,000 CHARACTERS, so a dense-script proposal arrives at up to
    # 128,000 bytes. One rung lands at 32,000 bytes — still over an 8192-token window — and
    # the gate fell open having performed NO novelty check at all, for exactly the articles
    # most likely to be re-captured. Three rungs reach the 8,000-byte floor from anywhere.
    provider(8_000, e([1.0]))

    assessment =
      ProposalGate.assess(tenant.id, %{
        "title" => "Changelog",
        "body" => String.duplicate("д", 30_000)
      })

    refute assessment.verdict == :unknown, "the gate skipped novelty checking entirely"
    assert assessment.score >= 0.97
  end
end
