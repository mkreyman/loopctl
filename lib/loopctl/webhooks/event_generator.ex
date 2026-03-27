defmodule Loopctl.Webhooks.EventGenerator do
  @moduledoc """
  Generates webhook event records inside Ecto.Multi transactions.

  When a state change occurs (story status change, verification, rejection,
  epic completion, artifact report, agent registration), this module queries
  active webhook subscriptions that match the event type and optional project
  scope, then inserts a `webhook_event` record for each matching webhook.

  Events are created atomically with the state change -- if the transaction
  rolls back, the webhook events are also rolled back. Oban delivery jobs
  are inserted in the same multi for transactional delivery scheduling.

  ## Usage

      Multi.new()
      |> Multi.update(:story, changeset)
      |> EventGenerator.generate_events(:webhook_events, %{
        tenant_id: tenant_id,
        event_type: "story.status_changed",
        project_id: project_id,
        payload: %{...}
      })

  ## TODO

  - Wire `project.imported` events when US-12.1 (Import/Export) is implemented.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Webhooks.Webhook
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.Workers.WebhookDeliveryWorker

  @doc """
  Appends webhook event generation steps to an Ecto.Multi pipeline.

  Queries active webhooks matching the event_type and project scope,
  then inserts one webhook_event per matching webhook plus an Oban
  delivery job for each event.

  ## Parameters

  - `multi` -- the Ecto.Multi struct
  - `name` -- step name in the multi (e.g., `:webhook_events`)
  - `event_params` -- map or function returning a map with:
    - `:tenant_id` -- required
    - `:event_type` -- required (e.g., "story.status_changed")
    - `:project_id` -- optional (for project-scoped webhooks)
    - `:payload` -- required (event data)

  When `event_params` is a function, it receives the accumulated multi
  changes and must return the params map.
  """
  @spec generate_events(Multi.t(), atom(), map() | (map() -> map())) :: Multi.t()
  def generate_events(multi, name, event_params) when is_map(event_params) do
    generate_events(multi, name, fn _changes -> event_params end)
  end

  def generate_events(multi, name, event_params_fn) when is_function(event_params_fn, 1) do
    Multi.run(multi, name, fn _repo, changes ->
      params = event_params_fn.(changes)
      tenant_id = Map.fetch!(params, :tenant_id)
      event_type = Map.fetch!(params, :event_type)
      project_id = Map.get(params, :project_id)
      payload = Map.fetch!(params, :payload)

      webhooks = matching_webhooks(tenant_id, event_type, project_id)

      events =
        Enum.map(webhooks, fn webhook ->
          {:ok, event} = insert_webhook_event(tenant_id, webhook.id, event_type, payload)

          # NOTE: Oban.insert/1 is safe inside Multi.run because Ecto checks
          # out one connection per process — all Repo operations within this
          # process (including Oban's internal Repo.insert) reuse the Multi's
          # transaction connection. If the Multi rolls back, the Oban job row
          # is also rolled back.
          {:ok, _job} =
            WebhookDeliveryWorker.new(%{
              webhook_event_id: event.id,
              tenant_id: tenant_id
            })
            |> Oban.insert()

          event
        end)

      {:ok, events}
    end)
  end

  @doc """
  Queries active webhooks that match the given event type and project scope.

  A webhook matches if:
  - It belongs to the tenant
  - It is active (active=true)
  - Its events list includes the event_type
  - Its project_id is NULL (all projects) or matches the given project_id
  """
  @spec matching_webhooks(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil) :: [Webhook.t()]
  def matching_webhooks(tenant_id, event_type, project_id) do
    Webhook
    |> where([w], w.tenant_id == ^tenant_id)
    |> where([w], w.active == true)
    |> where([w], ^event_type in w.events)
    |> filter_by_project(project_id)
    |> AdminRepo.all()
  end

  defp filter_by_project(query, nil) do
    # If no project_id given, only match global webhooks (project_id IS NULL)
    where(query, [w], is_nil(w.project_id))
  end

  defp filter_by_project(query, project_id) do
    # Match webhooks with this project_id OR global webhooks (project_id IS NULL)
    where(query, [w], is_nil(w.project_id) or w.project_id == ^project_id)
  end

  defp insert_webhook_event(tenant_id, webhook_id, event_type, payload) do
    %WebhookEvent{
      tenant_id: tenant_id,
      webhook_id: webhook_id
    }
    |> WebhookEvent.create_changeset(%{
      event_type: event_type,
      payload: payload
    })
    |> AdminRepo.insert()
  end
end
