defmodule Loopctl.Workers.ThreadIssueLinkWorkerTest do
  @moduledoc """
  US-45.7 (TC-45.7.4): the drain half — a pending link row becomes ONE comment on the intake
  issue carrying the thread page's URL, however often the worker runs. The row is written in
  the first checkpoint's transaction (`Loopctl.Threads.IssueLinksTest`, on the RLS `Repo`);
  the drain reads on `AdminRepo`, so each half is tested on its own sandbox connection, async.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ThreadIssueLinkWorker

  setup :verify_on_exit!

  test "a pending link is posted once with the thread URL, however often the worker runs" do
    tenant = fixture(:tenant)
    story = fixture(:story, %{tenant_id: tenant.id})

    fixture(:intake_record, %{
      tenant_id: tenant.id,
      repo: AdminRepo,
      repo_full_name: "acme/widgets"
    })

    fixture(:thread_issue_link, %{
      tenant_id: tenant.id,
      story_id: story.id,
      repo_full_name: "acme/widgets",
      issue_number: 314
    })

    url = ThreadIssueLinkWorker.thread_url(story.id)
    assert String.ends_with?(url, "/threads/#{story.id}")

    expect(Loopctl.MockPullRequestSource, :comment_issue, 1, fn "acme/widgets", 314, body ->
      assert body =~ url
      :ok
    end)

    assert :ok = ThreadIssueLinkWorker.perform(%Oban.Job{args: %{}})
    assert :ok = ThreadIssueLinkWorker.perform(%Oban.Job{args: %{}})
  end

  test "it drains pending rows only: a thread with no link row is not scanned for" do
    tenant = fixture(:tenant)
    story = fixture(:story, %{tenant_id: tenant.id})

    record =
      fixture(:intake_record, %{tenant_id: tenant.id, repo: AdminRepo, repo_full_name: "a/b"})

    AdminRepo.update_all(from(s in Story, where: s.id == ^story.id),
      set: [intake_record_id: record.id]
    )

    fixture(:thread_checkpoint, %{
      repo: AdminRepo,
      tenant_id: tenant.id,
      story_id: story.id,
      seq: 1,
      commit_sha: String.duplicate("a", 40)
    })

    expect(Loopctl.MockPullRequestSource, :comment_issue, 0, fn _, _, _ -> :ok end)
    assert :ok = ThreadIssueLinkWorker.perform(%Oban.Job{args: %{}})
  end

  test "the drainer is on the cron, every two minutes" do
    {Oban.Plugins.Cron, cron_opts} =
      Enum.find(
        Application.get_env(:loopctl, Oban)[:plugins],
        &match?({Oban.Plugins.Cron, _}, &1)
      )

    assert {"*/2 * * * *", ThreadIssueLinkWorker} in cron_opts[:crontab]
  end
end
