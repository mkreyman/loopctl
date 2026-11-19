defmodule Loopctl.Changes.SelectionProofTest do
  @moduledoc """
  US-51.5: the measured selection-widening proof, read from the verifier's recorded `verify@1`
  verdict and never from anything the implementer can write.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.AgentResult
  alias Loopctl.Changes.Finding
  alias Loopctl.Changes.SelectionProof
  alias Loopctl.Intake.Record
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @head String.duplicate("a", 40)
  @miss String.duplicate("b", 40)

  setup do
    tenant = fixture(:tenant)
    story = fixture(:detected_story, %{tenant_id: tenant.id})
    {_key, runner} = fixture(:runner, %{tenant_id: tenant.id})
    %{tenant: tenant, story: AdminRepo.get!(Story, story.id), runner: runner}
  end

  defp corpus(n, dropped \\ []) do
    for i <- 1..n do
      sha = i |> Integer.to_string() |> String.pad_leading(40, "c")
      %{"sha" => sha, "base_count" => 10, "head_count" => 12, "dropped" => dropped}
    end
  end

  defp verdict!(ctx, attrs) do
    dispatch_id = Ecto.UUID.generate()

    fixture(:accepted_dispatch, %{
      tenant_id: ctx.tenant.id,
      runner: ctx.runner,
      dispatch_id: dispatch_id,
      story_id: ctx.story.id,
      claim_epoch: 1,
      kind: Map.get(attrs, :kind, "verify")
    })

    result =
      Map.merge(
        %{"verdict" => "pass", "head_sha" => @head, "findings" => []},
        Map.get(attrs, :result, %{})
      )

    AdminRepo.update_all(from(r in DispatchRecord, where: r.dispatch_id == ^dispatch_id),
      set: [
        agent_result: result,
        agent_result_spec: "verify@1",
        agent_result_digest: String.duplicate("d", 64),
        agent_result_at: DateTime.utc_now()
      ]
    )

    %{ctx.story | verifier_dispatch_id: dispatch_id}
  end

  defp link_finding!(ctx, story, tenant_id \\ nil) do
    now = DateTime.utc_now()

    finding =
      AdminRepo.insert!(%Finding{
        tenant_id: tenant_id || ctx.tenant.id,
        kind: "selection_miss",
        fingerprint: "fp-#{System.unique_integer([:positive])}",
        repo_full_name: "mkreyman/chg",
        state: :filed,
        first_seen_at: now,
        last_seen_at: now,
        evidence: %{"sha" => @miss, "failures" => ["test/a_test.exs:1", "test/b_test.exs:2"]}
      })

    AdminRepo.update_all(from(r in Record, where: r.id == ^story.intake_record_id),
      set: [loop_finding_id: finding.id]
    )

    finding
  end

  defp replay(corpus, covered \\ nil) do
    base = %{"corpus" => corpus}
    if covered, do: Map.put(base, "miss", %{"sha" => @miss, "covered" => covered}), else: base
  end

  test "a widening replay over the corpus passes", ctx do
    story = verdict!(ctx, %{result: %{"selection_replay" => replay(corpus(5))}})
    assert SelectionProof.judge(story, @head) == :pass
  end

  test "a commit that drops a test refuses, naming it", ctx do
    narrowed = [%{"sha" => @miss, "base_count" => 10, "head_count" => 9, "dropped" => ["t9"]}]
    story = verdict!(ctx, %{result: %{"selection_replay" => replay(corpus(5) ++ narrowed)}})

    assert {:fail, [{:selection_narrowed, @miss, ["t9"]}]} = SelectionProof.judge(story, @head)
  end

  test "a fewer count with no names dropped is still a narrowing", ctx do
    narrowed = [%{"sha" => @miss, "base_count" => 10, "head_count" => 9, "dropped" => []}]
    story = verdict!(ctx, %{result: %{"selection_replay" => replay(corpus(5) ++ narrowed)}})

    assert {:fail, [{:selection_narrowed, @miss, []}]} = SelectionProof.judge(story, @head)
  end

  test "a corpus below the minimum refuses", ctx do
    story = verdict!(ctx, %{result: %{"selection_replay" => replay(corpus(2))}})

    assert {:fail, [{:selection_replay_corpus_too_small, 2, 5}]} =
             SelectionProof.judge(story, @head)
  end

  test "no verifier, no replay, or a reject refuses", ctx do
    assert {:fail, [:selection_replay_missing]} = SelectionProof.judge(ctx.story, @head)

    plain = verdict!(ctx, %{})
    assert {:fail, [:selection_replay_missing]} = SelectionProof.judge(plain, @head)

    rejected =
      verdict!(ctx, %{
        result: %{"verdict" => "reject", "selection_replay" => replay(corpus(5))}
      })

    assert {:fail, [:selection_replay_not_passed]} = SelectionProof.judge(rejected, @head)
  end

  test "a replay recorded for another head refuses", ctx do
    other = verdict!(ctx, %{result: %{"selection_replay" => replay(corpus(5))}})

    assert {:fail, [:selection_replay_for_other_head]} =
             SelectionProof.judge(other, String.duplicate("e", 40))
  end

  test "an implement dispatch's row is not a verifier's replay", ctx do
    story =
      verdict!(ctx, %{kind: "implement", result: %{"selection_replay" => replay(corpus(5))}})

    assert {:fail, [:selection_replay_missing]} = SelectionProof.judge(story, @head)
  end

  describe "the verify@1 result schema" do
    defp admit(replay) do
      AgentResult.admit(%{
        spec: %{id: "verify", version: 1},
        result: %{
          "verdict" => "pass",
          "head_sha" => @head,
          "findings" => [],
          "selection_replay" => replay
        }
      })
    end

    test "admits a bounded selection_replay, and a verdict without one" do
      assert {:ok, _} = admit(replay(corpus(30), ["test/a_test.exs:1"]))

      assert {:ok, _} =
               AgentResult.admit(%{
                 spec: %{id: "verify", version: 1},
                 result: %{"verdict" => "pass", "head_sha" => @head, "findings" => []}
               })
    end

    test "refuses a replay past its bounds or with unknown fields" do
      assert {:error, _} = admit(replay(corpus(31)))
      assert {:error, _} = admit(replay(corpus(1, ["a", "b", "c", "d"])))
      assert {:error, _} = admit(Map.put(replay(corpus(5)), "verdict", "pass"))
    end
  end

  describe "a story from a selection_miss finding" do
    test "passes only when the replay covers every test the gate failed", ctx do
      covered = ["test/a_test.exs:1", "test/b_test.exs:2"]
      story = verdict!(ctx, %{result: %{"selection_replay" => replay(corpus(5), covered)}})
      link_finding!(ctx, story)

      assert SelectionProof.judge(story, @head) == :pass
    end

    test "a failed test the head does not select refuses, naming it", ctx do
      story =
        verdict!(ctx, %{
          result: %{"selection_replay" => replay(corpus(5), ["test/a_test.exs:1"])}
        })

      link_finding!(ctx, story)

      assert {:fail, [{:selection_miss_not_covered, ["test/b_test.exs:2"]}]} =
               SelectionProof.judge(story, @head)
    end

    test "a replay with no miss, or of another commit, refuses", ctx do
      story = verdict!(ctx, %{result: %{"selection_replay" => replay(corpus(5))}})
      link_finding!(ctx, story)

      assert {:fail, [{:selection_replay_wrong_miss, @miss}]} =
               SelectionProof.judge(story, @head)
    end

    test "a finding cleared since (its issue number dropped) still demands its miss", ctx do
      story =
        verdict!(ctx, %{
          result: %{"selection_replay" => replay(corpus(5), ["test/a_test.exs:1"])}
        })

      finding = link_finding!(ctx, story)

      AdminRepo.update_all(from(f in Finding, where: f.id == ^finding.id),
        set: [issue_number: nil, cycle: 1, state: :queued]
      )

      assert {:fail, [{:selection_miss_not_covered, ["test/b_test.exs:2"]}]} =
               SelectionProof.judge(story, @head)
    end

    test "another tenant's finding on the record is not this story's", ctx do
      story = verdict!(ctx, %{result: %{"selection_replay" => replay(corpus(5))}})
      link_finding!(ctx, story, fixture(:tenant).id)

      # Not joined across tenants, so the story is judged as one with no finding.
      assert SelectionProof.judge(story, @head) == :pass
    end
  end
end
