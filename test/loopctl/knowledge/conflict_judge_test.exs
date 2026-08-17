defmodule Loopctl.Knowledge.ConflictJudgeTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.Knowledge.ConflictJudge
  alias Loopctl.Knowledge.ConflictJudge.Llm
  alias Loopctl.Knowledge.ConflictJudge.Similarity

  defmodule Contradicting do
    @moduledoc false
    @behaviour ConflictJudge
    @impl true
    def judge(_scope, _left, _right, _opts),
      do:
        {:ok,
         %{classification: :contradictory, confidence: :high, rationale: "A says X, B says not X"}}
  end

  defmodule Erroring do
    @moduledoc false
    @behaviour ConflictJudge
    @impl true
    def judge(_scope, _left, _right, _opts), do: {:error, :no_api_key}
  end

  defmodule Raising do
    @moduledoc false
    @behaviour ConflictJudge
    @impl true
    def judge(_scope, _left, _right, _opts), do: raise("boom")
  end

  defp left, do: %{id: "a", title: "Use advisory locks", body: "Take an advisory lock."}
  defp right, do: %{id: "b", title: "Do not use advisory locks", body: "Never take one."}

  describe "judge/5 — degradation is not optional" do
    # The queue must never stop being consumed because the judge got better. Each of these
    # is a distinct way the provider half can fail, and every one must still yield a usable
    # verdict rather than an error the caller has to handle.
    for {label, impl} <- [
          {"no API key", Erroring},
          {"a raise inside the implementation", Raising}
        ] do
      test "falls back to the similarity verdict on #{label}" do
        verdict =
          ConflictJudge.judge("t", left(), right(), 0.97, conflict_judge_impl: unquote(impl))

        assert verdict == Similarity.verdict(0.97)
        assert verdict.classification == :redundant
      end
    end

    test "the fallback still grades confidence by similarity, so the drain is unchanged" do
      assert %{confidence: :high} =
               ConflictJudge.judge("t", left(), right(), 0.99, conflict_judge_impl: Erroring)

      assert %{confidence: :medium} =
               ConflictJudge.judge("t", left(), right(), 0.80, conflict_judge_impl: Erroring)
    end

    test "disabled means the similarity verdict, with no implementation consulted" do
      assert ConflictJudge.judge("t", left(), right(), 0.9,
               conflict_judge: false,
               conflict_judge_impl: Raising
             ) == Similarity.verdict(0.9)
    end

    test "a working judge is what actually decides" do
      assert %{classification: :contradictory, confidence: :high} =
               ConflictJudge.judge("t", left(), right(), 0.9, conflict_judge_impl: Contradicting)
    end
  end

  describe "Similarity.verdict/1 — the historical behaviour, preserved verbatim" do
    test "is always redundant, and says why that is a limitation rather than a finding" do
      verdict = Similarity.verdict(0.96)

      assert verdict.classification == :redundant
      assert verdict.rationale =~ "cannot distinguish agreement from disagreement"
    end

    test "a nil similarity does not crash the nightly drain" do
      assert %{classification: :redundant, confidence: :medium} = Similarity.verdict(nil)
    end
  end

  describe "Llm.parse_verdict/1" do
    test "accepts the three classifications and maps confidence" do
      assert {:ok, %{classification: :redundant, confidence: :high}} =
               Llm.parse_verdict(
                 ~s({"classification":"redundant","confidence":"high","rationale":"same"})
               )

      assert {:ok, %{classification: :contradictory}} =
               Llm.parse_verdict(
                 ~s({"classification":"contradictory","confidence":"low","rationale":"x"})
               )

      assert {:ok, %{classification: :complementary}} =
               Llm.parse_verdict(
                 ~s({"classification":"complementary","confidence":"medium","rationale":"x"})
               )
    end

    test "tolerates a fence and a preamble" do
      assert {:ok, %{classification: :redundant}} =
               Llm.parse_verdict(~s|Sure:\n```json\n{"classification": "redundant"}\n```|)
    end

    test "an UNKNOWN classification is an error, never a silent :redundant" do
      # Defaulting here would make a broken prompt indistinguishable from a corpus with no
      # contradictions in it — precisely the state this judge exists to end.
      assert {:error, :unparseable_verdict} =
               Llm.parse_verdict(~s({"classification":"maybe","confidence":"high"}))

      assert {:error, :unparseable_verdict} = Llm.parse_verdict(~s({"confidence":"high"}))
      assert {:error, :unparseable_verdict} = Llm.parse_verdict("no json here")
      assert {:error, :unparseable_verdict} = Llm.parse_verdict(nil)
    end

    test "a missing or unknown confidence falls back to medium rather than failing" do
      # The classification must be exact; the confidence is a grade on it, and rejecting a
      # whole verdict over a missing grade would send a good judgement to the fallback.
      assert {:ok, %{confidence: :medium}} =
               Llm.parse_verdict(~s({"classification":"redundant"}))

      assert {:ok, %{confidence: :medium}} =
               Llm.parse_verdict(~s({"classification":"redundant","confidence":"very sure"}))
    end

    test "a contradictory verdict's evidence states that nothing is retired" do
      {:ok, verdict} =
        Llm.parse_verdict(
          ~s({"classification":"contradictory","confidence":"high","rationale":"A says X"})
        )

      assert verdict.rationale =~ "Both articles are RETAINED"
      assert verdict.rationale =~ "not something an unattended judge is entitled to do"
    end
  end

  describe "Llm.user_content/3" do
    test "labels the similarity as context, not as the answer" do
      content = Llm.user_content(left(), right(), 0.93)

      assert content =~ "0.93"
      assert content =~ "context only"
      assert content =~ "Use advisory locks"
      assert content =~ "Do not use advisory locks"
    end
  end
end
