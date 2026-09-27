defmodule Loopctl.Workers.ThreadIssueLinkWorkerTest do
  @moduledoc """
  US-45.7 (TC-45.7.4): an intake story whose thread has a checkpoint leads to ONE comment on its
  intake issue carrying the thread page's URL, however often the worker runs — for a thread
  recorded before the worker existed as much as for a new one.

  The worker derives the intent from the checkpoint rows and drains it, both on `AdminRepo`,
  so the whole path runs on that one sandbox connection, async.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ThreadIssueLinkWorker

  setup :verify_on_exit!

  test "the first checkpoint of an intake story leads to one comment with the thread URL" do
    tenant = fixture(:tenant)
    story = fixture(:story, %{tenant_id: tenant.id})

    record =
      fixture(:intake_record, %{
        tenant_id: tenant.id,
        repo: AdminRepo,
        repo_full_name: "acme/widgets",
        issue_number: 314
      })

    AdminRepo.update_all(from(s in Story, where: s.id == ^story.id),
      set: [intake_record_id: record.id]
    )

    for {seq, sha} <- [{1, "a"}, {2, "b"}] do
      fixture(:thread_checkpoint, %{
        repo: AdminRepo,
        tenant_id: tenant.id,
        story_id: story.id,
        seq: seq,
        commit_sha: String.duplicate(sha, 40)
      })
    end

    url = ThreadIssueLinkWorker.thread_url(story.id)
    assert String.ends_with?(url, "/threads/#{story.id}")

    expect(Loopctl.MockPullRequestSource, :comment_issue, 1, fn "acme/widgets", 314, body ->
      assert body =~ url
      :ok
    end)

    assert :ok = ThreadIssueLinkWorker.perform(%Oban.Job{args: %{}})
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
