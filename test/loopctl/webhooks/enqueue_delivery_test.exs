defmodule Loopctl.Webhooks.EnqueueDeliveryTest do
  @moduledoc """
  #885: a webhook event and its delivery job are written in one `AdminRepo` transaction, so
  neither commits without the other. A bare `Oban.insert/1` wrote the job on Loopctl.Repo,
  where it committed at once, could run before the event was visible, and survived the
  event's transaction rolling back.
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Repo
  alias Loopctl.Webhooks
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Webhooks.WebhookEvent

  @worker_file "lib/loopctl/workers/webhook_delivery_worker.ex"
  @module_names [
    "Loopctl.Workers.WebhookDeliveryWorker",
    "Elixir.Loopctl.Workers.WebhookDeliveryWorker"
  ]

  defp job_for(event_id) do
    AdminRepo.one(
      from(j in Oban.Job, where: fragment("?->>'webhook_event_id'", j.args) == ^event_id)
    )
  end

  # The sandbox gives each repo its own connection, so a job written on Loopctl.Repo (the
  # #885 defect) is invisible to AdminRepo. Look on both.
  defp job_anywhere(event_id) do
    job_for(event_id) ||
      Repo.one(
        from(j in Oban.Job, where: fragment("?->>'webhook_event_id'", j.args) == ^event_id)
      )
  end

  defp event_row(event_id), do: AdminRepo.get(WebhookEvent, event_id)

  defp payload, do: %{"event" => "story.status_changed"}

  describe "Webhooks.insert_event_with_delivery/4" do
    setup do
      webhook = fixture(:webhook, %{})
      %{webhook: webhook}
    end

    test "writes the event and its job inside the caller's AdminRepo transaction", %{
      webhook: webhook
    } do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, event} =
          AdminRepo.transaction(fn ->
            {:ok, event} =
              Webhooks.insert_event_with_delivery(
                webhook.tenant_id,
                webhook.id,
                "story.status_changed",
                payload()
              )

            # Visible on the transaction's own connection before it commits: the job is part
            # of this transaction, not a separate one that committed already.
            assert %Oban.Job{args: args, queue: "webhooks"} = job_for(event.id)
            assert args == %{"webhook_event_id" => event.id, "tenant_id" => webhook.tenant_id}
            event
          end)

        assert %WebhookEvent{} = event_row(event.id)
        assert %Oban.Job{} = job_for(event.id)
      end)
    end

    test "rolls back the event and its job with the caller's transaction", %{webhook: webhook} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {:error, {:rolled_back, event_id}} =
          AdminRepo.transaction(fn ->
            {:ok, event} =
              Webhooks.insert_event_with_delivery(
                webhook.tenant_id,
                webhook.id,
                "story.status_changed",
                payload()
              )

            AdminRepo.rollback({:rolled_back, event.id})
          end)

        assert event_row(event_id) == nil
        assert job_anywhere(event_id) == nil
      end)
    end

    test "outside any transaction, commits the event and its job on AdminRepo", %{
      webhook: webhook
    } do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, event} =
          Webhooks.insert_event_with_delivery(
            webhook.tenant_id,
            webhook.id,
            "story.status_changed",
            payload()
          )

        assert %WebhookEvent{status: :pending} = event_row(event.id)
        assert %Oban.Job{worker: "Loopctl.Workers.WebhookDeliveryWorker"} = job_for(event.id)
      end)
    end

    test "an invalid event is refused before any write and leaves the caller's transaction usable",
         %{webhook: webhook} do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, {refusal, event}} =
          AdminRepo.transaction(fn ->
            refusal =
              Webhooks.insert_event_with_delivery(
                webhook.tenant_id,
                webhook.id,
                "story.status_changed",
                nil
              )

            # The caller logs the refusal and carries on: its next write still commits.
            {:ok, event} =
              Webhooks.insert_event_with_delivery(
                webhook.tenant_id,
                webhook.id,
                "story.status_changed",
                payload()
              )

            {refusal, event}
          end)

        assert {:error, %Ecto.Changeset{valid?: false}} = refusal
        assert %WebhookEvent{} = event_row(event.id)
      end)
    end

    test "a database refusal inside the caller's transaction raises instead of returning",
         %{webhook: webhook} do
      missing_webhook_id = Ecto.UUID.generate()

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert_raise RuntimeError, ~r/webhook event write refused/, fn ->
          AdminRepo.transaction(fn ->
            Webhooks.insert_event_with_delivery(
              webhook.tenant_id,
              missing_webhook_id,
              "story.status_changed",
              payload()
            )
          end)
        end
      end)
    end

    test "a database refusal outside a transaction returns the error and writes nothing", %{
      webhook: webhook
    } do
      missing_webhook_id = Ecto.UUID.generate()

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:error, %Ecto.Changeset{}} =
                 Webhooks.insert_event_with_delivery(
                   webhook.tenant_id,
                   missing_webhook_id,
                   "story.status_changed",
                   payload()
                 )

        assert AdminRepo.aggregate(
                 from(e in WebhookEvent, where: e.webhook_id == ^missing_webhook_id),
                 :count
               ) == 0
      end)
    end
  end

  describe "EventGenerator.generate_events/3" do
    test "refuses to run outside an AdminRepo transaction" do
      webhook = fixture(:webhook, %{events: ["story.status_changed"]})

      multi =
        EventGenerator.generate_events(Multi.new(), :webhook_events, %{
          tenant_id: webhook.tenant_id,
          event_type: "story.status_changed",
          payload: payload()
        })

      assert_raise ArgumentError, ~r/AdminRepo transaction/, fn ->
        Repo.transaction(multi)
      end
    end
  end

  describe "enqueue guard" do
    # Every writer must go through Webhooks.insert_event_with_delivery/4. A job built any
    # other way is inserted through Oban's configured Loopctl.Repo and reopens #885 without a
    # failing test. Reads the AST, so docs that name the worker do not count and code that
    # reaches it indirectly does.
    test "no module under lib/ enqueues WebhookDeliveryWorker except through enqueue/3" do
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&(&1 == @worker_file))
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> Code.string_to_quoted!()
          |> foreign_enqueues()
          |> Enum.map(&"#{path}: #{&1}")
        end)

      assert offenders == []
    end

    test "the worker builds and inserts its own job only inside enqueue/3" do
      ast = @worker_file |> File.read!() |> Code.string_to_quoted!()

      assert count(ast, &local_new?/1) == 1
      assert count(ast, &oban_insert?/1) == 1

      {:def, _, [{:enqueue, _, _}, [do: body]]} =
        find(ast, &match?({:def, _, [{:enqueue, _, _} | _]}, &1))

      assert count(body, &local_new?/1) == 1
      assert count(body, &oban_insert?/1) == 1
    end

    test "flags every way of building the job" do
      for source <- [
            "WebhookDeliveryWorker.new(%{})",
            "Loopctl.Workers.WebhookDeliveryWorker.new(%{})",
            "alias Loopctl.Workers.WebhookDeliveryWorker, as: Delivery",
            "Oban.Job.new(%{}, worker: WebhookDeliveryWorker)",
            ~s|Oban.Job.new(%{}, worker: "Loopctl.Workers.WebhookDeliveryWorker")|,
            ~s|%Oban.Job{worker: "Loopctl.Workers.WebhookDeliveryWorker"}|
          ] do
        assert [_] = source |> Code.string_to_quoted!() |> foreign_enqueues(), source
      end
    end

    test "leaves reads of the worker's jobs alone" do
      for source <- [
            ~s|from(j in Oban.Job, where: j.worker == "Loopctl.Workers.WebhookDeliveryWorker")|,
            "Oban.Job |> where(worker: ^inspect(WebhookDeliveryWorker)) |> Repo.all()",
            "Oban.Testing.assert_enqueued(worker: WebhookDeliveryWorker)"
          ] do
        assert [] = source |> Code.string_to_quoted!() |> foreign_enqueues(), source
      end
    end
  end

  defp foreign_enqueues(ast) do
    collect(ast, fn
      {{:., _, [{:__aliases__, _, parts}, :new]}, _, _} = node ->
        cond do
          List.last(parts) == :WebhookDeliveryWorker -> Macro.to_string(node)
          names_worker_job?(node) -> Macro.to_string(node)
          true -> nil
        end

      {:alias, _, [{:__aliases__, _, parts}, opts]} = node when is_list(opts) ->
        if List.last(parts) == :WebhookDeliveryWorker and Keyword.has_key?(opts, :as),
          do: Macro.to_string(node)

      {:%, _, [_struct, {:%{}, _, fields}]} = node when is_list(fields) ->
        if worker_ref?(Keyword.get(fields, :worker)), do: Macro.to_string(node)

      _ ->
        nil
    end)
  end

  # A `new` call whose options name the worker: `Oban.Job.new(args, worker: ...)`.
  defp names_worker_job?({_call, _, args}) do
    Enum.any?(args, fn
      opts when is_list(opts) -> Keyword.keyword?(opts) and worker_ref?(opts[:worker])
      _ -> false
    end)
  end

  defp worker_ref?({:__aliases__, _, parts}), do: List.last(parts) == :WebhookDeliveryWorker
  defp worker_ref?(string) when is_binary(string), do: string in @module_names
  defp worker_ref?(_), do: false

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
