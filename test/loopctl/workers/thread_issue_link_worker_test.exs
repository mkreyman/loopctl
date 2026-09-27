defmodule Loopctl.Workers.ThreadIssueLinkWorkerTest do
  @moduledoc """
  US-45.7 (TC-45.7.4): the first checkpoint of an intake story leads to ONE comment on its
  intake issue carrying the thread page's URL, however often the drainer runs.

  `async: false`: the checkpoint is recorded on the RLS `Repo` and the drainer reads on
  `AdminRepo`, separate sandbox connections, so the story, its claim and its checkpoint are
  committed and swept (`sweep_committed_runner_tenants/0`).
  """

  use Loopctl.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.Repo
  alias Loopctl.Threads
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ThreadIssueLinkWorker

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @epoch 1

  test "the first checkpoint of an intake story posts one comment with the thread URL" do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {_raw, _key, agent} = fixture(:committed_agent_key, %{tenant_id: tenant.id})
    {source, record} = fixture(:committed_intake, %{tenant_id: tenant.id})
    story = fixture(:committed_story, %{tenant_id: tenant.id})

    Sandbox.unboxed_run(Repo, fn ->
      {:ok, _} =
        Repo.with_tenant(tenant.id, fn ->
          from(s in Story, where: s.id == ^story.id)
          |> Repo.update_all(
            set: [
              assigned_agent_id: agent.id,
              agent_status: :implementing,
              claim_epoch: @epoch,
              claimed_until: DateTime.add(DateTime.utc_now(), 3_600),
              intake_record_id: record.id
            ]
          )
        end)

      for sha <- [String.duplicate("a", 40), String.duplicate("b", 40)] do
        {:ok, _cp, :created} =
          Threads.record_checkpoint(tenant.id, story.id,
            agent_id: agent.id,
            claim_epoch: @epoch,
            commit_sha: sha,
            tree_sha: String.duplicate("c", 40),
            author_principal: "agent:#{agent.id}",
            actor_lineage: []
          )
      end
    end)

    repo = source.repo_full_name
    number = record.issue_number
    url = ThreadIssueLinkWorker.thread_url(story.id)
    assert String.ends_with?(url, "/threads/#{story.id}")

    expect(Loopctl.MockPullRequestSource, :comment_issue, 1, fn ^repo, ^number, body ->
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
