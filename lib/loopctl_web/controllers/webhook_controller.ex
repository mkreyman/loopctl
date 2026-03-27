defmodule LoopctlWeb.WebhookController do
  @moduledoc """
  Controller for webhook subscription management.

  - `POST /api/v1/webhooks` -- create webhook (user role)
  - `GET /api/v1/webhooks` -- list webhooks (user role)
  - `PATCH /api/v1/webhooks/:id` -- update webhook (user role)
  - `DELETE /api/v1/webhooks/:id` -- delete webhook (user role)
  """

  use LoopctlWeb, :controller

  alias Loopctl.Webhooks

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user

  @doc """
  POST /api/v1/webhooks

  Creates a new webhook subscription. Returns the signing secret once.
  """
  def create(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    attrs = %{
      "url" => params["url"],
      "events" => params["events"],
      "project_id" => params["project_id"]
    }

    case Webhooks.create_webhook(tenant_id, attrs,
           actor_id: api_key.id,
           actor_label: actor_label(api_key)
         ) do
      {:ok, %{webhook: webhook, signing_secret: secret}} ->
        conn
        |> put_status(:created)
        |> json(%{webhook: webhook_json_with_secret(webhook, secret)})

      {:error, :webhook_limit_reached} ->
        {:error, :unprocessable_entity, "Webhook limit reached for this tenant"}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  GET /api/v1/webhooks

  Lists all webhook subscriptions for the authenticated tenant.
  """
  def index(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts = [
      page: parse_int(params["page"]),
      page_size: parse_int(params["page_size"])
    ]

    opts = Enum.reject(opts, fn {_k, v} -> is_nil(v) end)

    {:ok, result} = Webhooks.list_webhooks(tenant_id, opts)

    json(conn, %{
      data: Enum.map(result.data, &webhook_json/1),
      meta: %{
        page: result.page,
        page_size: result.page_size,
        total_count: result.total,
        total_pages: ceil_div(result.total, result.page_size)
      }
    })
  end

  @doc """
  PATCH /api/v1/webhooks/:id

  Updates a webhook subscription.
  """
  def update(conn, %{"id" => webhook_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    attrs =
      params
      |> Map.take(["url", "events", "project_id", "active"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Webhooks.update_webhook(tenant_id, webhook_id, attrs,
           actor_id: api_key.id,
           actor_label: actor_label(api_key)
         ) do
      {:ok, webhook} ->
        json(conn, %{webhook: webhook_json(webhook)})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  POST /api/v1/webhooks/:id/test

  Sends a test event to the webhook endpoint. Works even on inactive webhooks.
  """
  def test(conn, %{"id" => webhook_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case Webhooks.test_webhook(tenant_id, webhook_id) do
      {:ok, event} ->
        json(conn, %{
          webhook_event_id: event.id,
          status: "pending",
          message: "Test event created and enqueued for delivery"
        })

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  GET /api/v1/webhooks/:id/deliveries

  Lists recent delivery attempts for a webhook.
  """
  def deliveries(conn, %{"id" => webhook_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    opts = [
      page: parse_int(params["page"]),
      page_size: parse_int(params["page_size"])
    ]

    opts = Enum.reject(opts, fn {_k, v} -> is_nil(v) end)

    case Webhooks.list_deliveries(tenant_id, webhook_id, opts) do
      {:ok, result} ->
        json(conn, %{
          data: Enum.map(result.data, &delivery_json/1),
          meta: %{
            page: result.page,
            page_size: result.page_size,
            total_count: result.total,
            total_pages: ceil_div(result.total, result.page_size)
          }
        })

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  DELETE /api/v1/webhooks/:id

  Deletes a webhook and all its pending events.
  """
  def delete(conn, %{"id" => webhook_id}) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    case Webhooks.delete_webhook(tenant_id, webhook_id,
           actor_id: api_key.id,
           actor_label: actor_label(api_key)
         ) do
      {:ok, _webhook} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Private helpers ---

  defp webhook_json(webhook) do
    %{
      id: webhook.id,
      url: webhook.url,
      events: webhook.events,
      project_id: webhook.project_id,
      active: webhook.active,
      consecutive_failures: webhook.consecutive_failures,
      last_delivery_at: webhook.last_delivery_at,
      inserted_at: webhook.inserted_at,
      updated_at: webhook.updated_at
    }
  end

  defp delivery_json(event) do
    %{
      id: event.id,
      event_type: event.event_type,
      status: event.status,
      attempts: event.attempts,
      delivered_at: event.delivered_at,
      error: event.error,
      inserted_at: event.inserted_at
    }
  end

  defp webhook_json_with_secret(webhook, secret) do
    webhook
    |> webhook_json()
    |> Map.put(:signing_secret, secret)
  end

  defp actor_label(api_key) do
    "#{api_key.role}:#{api_key.name}"
  end

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val

  defp ceil_div(total, page_size), do: div(total + page_size - 1, page_size)
end
