defmodule Loopctl.Webhooks.EnqueueDeliveryTest do
  @moduledoc """
  #885: a webhook delivery job is written on the connection that wrote its event, so it
  commits or rolls back with it. On the main Oban instance (Loopctl.Repo) the job committed
  at once on another connection, could run before the event was visible, and survived the
  event's transaction rolling back.
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.ObanConfig
  alias Loopctl.Repo
  alias Loopctl.Workers.WebhookDeliveryWorker

  defp job_row(job_id), do: AdminRepo.one(from(j in Oban.Job, where: j.id == ^job_id))

  # The sandbox gives each repo its own connection, so a job written on Loopctl.Repo (the
  # main instance, the #885 defect) is invisible to AdminRepo. Look on both.
  defp job_row_anywhere(job_id) do
    job_row(job_id) || Repo.one(from(j in Oban.Job, where: j.id == ^job_id))
  end

  describe "WebhookDeliveryWorker.enqueue/2" do
    test "writes the job inside the caller's AdminRepo transaction" do
      event = fixture(:webhook_event, %{})

      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, job} =
          AdminRepo.transaction(fn ->
            {:ok, job} = WebhookDeliveryWorker.enqueue(event.tenant_id, event.id)

            # Visible on the transaction's own connection before it commits: the job is
            # part of this transaction, not a separate one that committed already.
            assert %Oban.Job{args: args, queue: "webhooks"} = job_row(job.id)
            assert args == %{"webhook_event_id" => event.id, "tenant_id" => event.tenant_id}
            job
          end)

        assert %Oban.Job{} = job_row(job.id)
      end)
    end

    test "rolls back with the transaction that enqueued it" do
      event = fixture(:webhook_event, %{})

      Oban.Testing.with_testing_mode(:manual, fn ->
        {:error, {:rolled_back, job_id}} =
          AdminRepo.transaction(fn ->
            {:ok, job} = WebhookDeliveryWorker.enqueue(event.tenant_id, event.id)
            AdminRepo.rollback({:rolled_back, job.id})
          end)

        assert job_row_anywhere(job_id) == nil
      end)
    end
  end

  describe "ObanConfig.admin_inserter/1" do
    test "is an insert-only instance on AdminRepo that inherits testing and prefix" do
      opts = ObanConfig.admin_inserter(testing: :inline, prefix: "private", queues: [a: 1])

      assert opts[:name] == Loopctl.AdminOban
      assert opts[:repo] == Loopctl.AdminRepo
      assert opts[:queues] == false
      assert opts[:plugins] == false
      assert opts[:peer] == false
      assert opts[:testing] == :inline
      assert opts[:prefix] == "private"
    end

    test "defaults to production behaviour when the main config sets neither" do
      opts = ObanConfig.admin_inserter([])

      assert opts[:testing] == :disabled
      assert opts[:prefix] == "public"
    end
  end

  describe "enqueue guard" do
    # Every writer must go through enqueue/2. A new writer that builds the job with new/1
    # and Oban.insert/1 puts it back on Loopctl.Repo and reopens #885 without a failing test.
    test "no module under lib/ enqueues WebhookDeliveryWorker except through enqueue/2" do
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, "workers/webhook_delivery_worker.ex"))
        |> Enum.filter(&(File.read!(&1) =~ ~r/WebhookDeliveryWorker\s*\.\s*new\b/))

      assert offenders == []
    end
  end
end
