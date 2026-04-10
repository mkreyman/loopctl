defmodule Loopctl.Progress.KnowledgeAutoExtractTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Progress

  defp setup_story(tenant_attrs \\ %{}) do
    tenant = fixture(:tenant, tenant_attrs)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})

    story =
      fixture(:story, %{
        tenant_id: tenant.id,
        epic_id: epic.id,
        agent_status: :reported_done,
        reported_done_at: DateTime.utc_now()
      })

    reviewer = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    %{tenant: tenant, story: story, reviewer: reviewer}
  end

  # --- TC-21.6.1: Record review enqueues knowledge worker when auto_extract enabled ---

  describe "record_review enqueues worker when auto_extract enabled" do
    test "enqueues ReviewKnowledgeWorker by default (auto_extract true)" do
      %{tenant: tenant, story: story, reviewer: reviewer} = setup_story()

      # The mock extractor is stubbed by default to return {:ok, []}.
      # If the worker is enqueued (inline mode), it will call extract_articles.
      # We verify it's called (meaning the worker was enqueued).
      expect(Loopctl.MockExtractor, :extract_articles, fn _ctx ->
        {:ok, []}
      end)

      assert {:ok, review_record} =
               Progress.record_review(
                 tenant.id,
                 story.id,
                 %{
                   "review_type" => "enhanced",
                   "findings_count" => 0,
                   "summary" => "Clean review."
                 },
                 reviewer_agent_id: reviewer.id
               )

      assert review_record.id != nil
    end

    test "enqueues worker when knowledge_auto_extract is explicitly true" do
      %{tenant: tenant, story: story, reviewer: reviewer} =
        setup_story(%{settings: %{"knowledge_auto_extract" => true}})

      expect(Loopctl.MockExtractor, :extract_articles, fn _ctx ->
        {:ok, []}
      end)

      assert {:ok, _} =
               Progress.record_review(
                 tenant.id,
                 story.id,
                 %{
                   "review_type" => "enhanced",
                   "findings_count" => 0,
                   "summary" => "All good."
                 },
                 reviewer_agent_id: reviewer.id
               )
    end
  end

  # --- TC-21.6.2: Record review skips worker when auto_extract disabled ---

  describe "record_review skips worker when auto_extract disabled" do
    test "does not enqueue worker when knowledge_auto_extract is false" do
      %{tenant: tenant, story: story, reviewer: reviewer} =
        setup_story(%{settings: %{"knowledge_auto_extract" => false}})

      # The extractor should NOT be called because auto_extract is disabled.
      # Using expect with count 0 will fail if the mock is called.
      expect(Loopctl.MockExtractor, :extract_articles, 0, fn _ctx ->
        {:ok, []}
      end)

      assert {:ok, review_record} =
               Progress.record_review(
                 tenant.id,
                 story.id,
                 %{
                   "review_type" => "enhanced",
                   "findings_count" => 0,
                   "summary" => "Review completed."
                 },
                 reviewer_agent_id: reviewer.id
               )

      # The review record should still be created successfully
      assert review_record.id != nil
      assert review_record.review_type == "enhanced"
    end
  end
end
