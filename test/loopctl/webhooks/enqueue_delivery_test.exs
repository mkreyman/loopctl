defmodule Loopctl.Webhooks.EnqueueDeliveryTest do
  @moduledoc """
  #885: a webhook delivery job is written on the connection that wrote its event, so it
  commits or rolls back with it. A bare `Oban.insert/1` wrote on Loopctl.Repo, where the job
  committed at once, could run before the event was visible, and survived the event's
  transaction rolling back.
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Repo
  alias Loopctl.Workers.WebhookDeliveryWorker

  @worker_file "lib/loopctl/workers/webhook_delivery_worker.ex"
  @module_names [
    "Loopctl.Workers.WebhookDeliveryWorker",
    "Elixir.Loopctl.Workers.WebhookDeliveryWorker"
  ]

  defp job_row(job_id), do: AdminRepo.one(from(j in Oban.Job, where: j.id == ^job_id))

  # The sandbox gives each repo its own connection, so a job written on Loopctl.Repo (the
  # #885 defect) is invisible to AdminRepo. Look on both.
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

    test "outside any transaction, commits the job on AdminRepo" do
      event = fixture(:webhook_event, %{})

      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, job} = WebhookDeliveryWorker.enqueue(event.tenant_id, event.id)

        assert %Oban.Job{worker: "Loopctl.Workers.WebhookDeliveryWorker"} = job_row(job.id)
      end)
    end
  end

  describe "enqueue guard" do
    # Every writer must go through enqueue/2. A job built any other way is inserted through
    # Oban's configured Loopctl.Repo and reopens #885 without a failing test. Reads the AST,
    # so docs that name the worker do not count and code that reaches it indirectly does.
    test "no module under lib/ enqueues WebhookDeliveryWorker except through enqueue/2" do
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&(&1 == @worker_file))
        |> Enum.flat_map(fn path -> Enum.map(foreign_enqueues(path), &"#{path}: #{&1}") end)

      assert offenders == []
    end

    test "the worker builds and inserts its own job only inside enqueue/2" do
      ast = @worker_file |> File.read!() |> Code.string_to_quoted!()

      assert count(ast, &local_new?/1) == 1
      assert count(ast, &oban_insert?/1) == 1

      {:def, _, [{:enqueue, _, _}, [do: body]]} =
        find(ast, &match?({:def, _, [{:enqueue, _, _} | _]}, &1))

      assert count(body, &local_new?/1) == 1
      assert count(body, &oban_insert?/1) == 1
    end
  end

  defp foreign_enqueues(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!()
    |> collect(fn
      {{:., _, [{:__aliases__, _, parts}, :new]}, _, _} = node ->
        if List.last(parts) == :WebhookDeliveryWorker, do: Macro.to_string(node)

      {:alias, _, [{:__aliases__, _, parts}, opts]} = node when is_list(opts) ->
        if List.last(parts) == :WebhookDeliveryWorker and Keyword.has_key?(opts, :as),
          do: Macro.to_string(node)

      {:worker, {:__aliases__, _, parts}} = node ->
        if List.last(parts) == :WebhookDeliveryWorker, do: Macro.to_string(node)

      string when is_binary(string) ->
        if string in @module_names, do: inspect(string)

      _ ->
        nil
    end)
  end

  defp local_new?({:new, _, [_ | _]}), do: true
  defp local_new?({{:., _, [{:__MODULE__, _, _}, :new]}, _, _}), do: true
  defp local_new?(_), do: false

  defp oban_insert?({{:., _, [{:__aliases__, _, [:Oban]}, insert]}, _, _})
       when insert in [:insert, :insert!, :insert_all],
       do: true

  defp oban_insert?(_), do: false

  defp collect(ast, fun) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        case fun.(node) do
          nil -> {node, acc}
          hit -> {node, [hit | acc]}
        end
      end)

    Enum.reverse(found)
  end

  defp count(ast, pred), do: length(collect(ast, &if(pred.(&1), do: true)))

  defp find(ast, pred), do: ast |> collect(&if(pred.(&1), do: &1)) |> List.first()
end
