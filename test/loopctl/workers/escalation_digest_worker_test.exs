defmodule Loopctl.Workers.EscalationDigestWorkerTest do
  @moduledoc """
  US-48.11 (AC-48.11.5): the daily job around `EscalationInbox.post_digest/2` — that a run
  posts, that a second run the same day posts nothing new, and that one tenant's failure
  neither stops the rest nor passes for a clean run. Selection, body and key are tested in
  `Loopctl.Delivery.EscalationInboxTest`.
  """

  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Workers.EscalationDigestWorker

  setup :verify_on_exit!

  defp post_count(tenant_id) do
    AdminRepo.aggregate(from(p in ChannelPost, where: p.tenant_id == ^tenant_id), :count)
  end

  defp two_hours_ago, do: DateTime.add(DateTime.utc_now(), -7_200, :second)

  describe "perform/1" do
    test "posts each qualifying project once, and a rerun the same day posts nothing" do
      %{story: story} = fixture(:escalated_story, %{escalated_at: two_hours_ago()})

      assert :ok = perform_job(EscalationDigestWorker, %{})
      assert post_count(story.tenant_id) == 1

      assert :ok = perform_job(EscalationDigestWorker, %{})
      assert post_count(story.tenant_id) == 1
    end

    test "TC-48.11.2: two runs, two projects — one post per project, whatever its reason class" do
      %{story: busy} = fixture(:escalated_story, %{escalated_at: two_hours_ago()})

      # Same tenant, another project: escalated at a refused merge gate, not over a budget.
      %{story: other} =
        fixture(:escalated_story, %{
          tenant_id: busy.tenant_id,
          edge: :merge_gate,
          from: :ci,
          ledger: false,
          escalated_at: two_hours_ago()
        })

      assert other.project_id != busy.project_id

      assert :ok = perform_job(EscalationDigestWorker, %{})
      assert :ok = perform_job(EscalationDigestWorker, %{})

      by_project =
        AdminRepo.all(from(p in ChannelPost, where: p.tenant_id == ^busy.tenant_id))
        |> Map.new(&{&1.project_id, &1.body})

      assert map_size(by_project) == 2
      assert by_project[busy.project_id] =~ "#{busy.id} budget_exhausted"
      assert by_project[other.project_id] =~ "#{other.id} gate_refused"
      refute by_project[busy.project_id] =~ other.id
    end

    test "an escalation younger than an hour is not digested yet" do
      %{story: story} = fixture(:escalated_story, %{})

      assert :ok = perform_job(EscalationDigestWorker, %{})
      assert post_count(story.tenant_id) == 0
    end

    test "a run with nothing escalated anywhere is clean" do
      assert :ok = perform_job(EscalationDigestWorker, %{})
    end
  end

  describe "digest/2" do
    test "is :ok for a tenant it posted for" do
      %{story: story} = fixture(:escalated_story, %{escalated_at: two_hours_ago()})

      assert :ok = EscalationDigestWorker.digest(story.tenant_id, DateTime.utc_now())
      assert post_count(story.tenant_id) == 1
    end

    test "turns a raise into :errored and logs it, instead of stopping the run" do
      log =
        capture_log(fn ->
          assert :errored = EscalationDigestWorker.digest("not-a-uuid", DateTime.utc_now())
        end)

      assert log =~ "tenant failed, continuing with the rest"
    end
  end

  describe "run_result/1" do
    test "fails only when every tenant errored" do
      assert EscalationDigestWorker.run_result([]) == :ok
      assert EscalationDigestWorker.run_result([:ok, :errored]) == :ok
      assert EscalationDigestWorker.run_result([:ok]) == :ok

      assert EscalationDigestWorker.run_result([:errored, :errored]) ==
               {:error, {:all_tenants_errored, 2}}
    end
  end
end
