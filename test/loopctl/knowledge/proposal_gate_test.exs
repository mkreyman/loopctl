defmodule Loopctl.Knowledge.ProposalGateTest do
  use Loopctl.DataCase, async: true

  import Mox

  setup :verify_on_exit!

  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.ProposalGate

  @dims 1536

  # Sparse-prefix embedding, rest zero-filled. Cosine is magnitude-independent, so
  # e([1.0]) vs e([1.0]) = 1.0, e([1.0]) vs e([0.0, 1.0]) = 0.0 (orthogonal),
  # e([1.0]) vs e([1.0, 0.426]) ≈ 0.92.
  defp e(prefix), do: prefix ++ List.duplicate(0.0, @dims - length(prefix))

  defp published_with_embedding(tenant_id, title, prefix) do
    a = fixture(:article, %{tenant_id: tenant_id, title: title, status: :published})
    {:ok, _} = Knowledge.update_embedding(tenant_id, a.id, e(prefix))
    a
  end

  describe "classify/3 (pure threshold logic)" do
    test "nil score (nothing above the overlap floor) is novel" do
      assert ProposalGate.classify(nil, 0.97, 0.88) == :novel
    end

    test "at/above the duplicate threshold is :duplicate" do
      assert ProposalGate.classify(0.97, 0.97, 0.88) == :duplicate
      assert ProposalGate.classify(0.991, 0.97, 0.88) == :duplicate
    end

    test "in the overlap band [overlap, duplicate) is :low_novelty" do
      assert ProposalGate.classify(0.88, 0.97, 0.88) == :low_novelty
      assert ProposalGate.classify(0.93, 0.97, 0.88) == :low_novelty
    end

    test "below the overlap floor is :novel" do
      assert ProposalGate.classify(0.8799, 0.97, 0.88) == :novel
      assert ProposalGate.classify(0.1, 0.97, 0.88) == :novel
    end
  end

  describe "assess/3 (real pgvector)" do
    setup do
      tenant = fixture(:tenant)
      existing = published_with_embedding(tenant.id, "Supervisors and OTP", [1.0])
      %{tenant: tenant, existing: existing}
    end

    test "an identical-direction proposal is a duplicate", %{tenant: tenant, existing: existing} do
      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, e([1.0])}
      end)

      assessment = ProposalGate.assess(tenant.id, %{"title" => "Supervisors", "body" => "OTP"})

      assert assessment.verdict == :duplicate
      assert assessment.score >= 0.97
      assert [%{id: id} | _] = assessment.neighbors
      assert id == existing.id
    end

    test "a high-overlap proposal is low-novelty", %{tenant: tenant} do
      # cos(e([1.0]), e([1.0, 0.426])) ≈ 0.92 — inside [0.88, 0.97).
      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, e([1.0, 0.426])}
      end)

      assessment = ProposalGate.assess(tenant.id, %{"title" => "Supervision", "body" => "trees"})

      assert assessment.verdict == :low_novelty
      assert assessment.score >= 0.88 and assessment.score < 0.97
    end

    test "an orthogonal proposal is novel (no neighbor clears the floor)", %{tenant: tenant} do
      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:ok, e([0.0, 1.0])}
      end)

      assessment = ProposalGate.assess(tenant.id, %{"title" => "Billing", "body" => "invoices"})

      assert assessment.verdict == :novel
      assert assessment.neighbors == []
    end

    test "falls OPEN (:unknown) when embedding fails — never blocks a write", %{tenant: tenant} do
      stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
        {:error, :timeout}
      end)

      assessment = ProposalGate.assess(tenant.id, %{"title" => "X", "body" => "Y"})

      assert assessment.verdict == :unknown
      assert assessment.score == nil
      assert assessment.neighbors == []
    end

    test "system scope (nil tenant) skips the gate" do
      assert %{verdict: :unknown, neighbors: []} =
               ProposalGate.assess(nil, %{"title" => "X", "body" => "Y"})
    end
  end
end
