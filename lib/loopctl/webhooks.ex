defmodule Loopctl.Webhooks do
  @moduledoc """
  Context module for webhook subscription management.

  Webhooks allow tenants to receive real-time push notifications when
  state changes occur in loopctl. Each webhook defines a delivery URL,
  a signing secret (encrypted via Cloak), and a list of event types.

  All operations are tenant-scoped via `tenant_id` and include audit
  logging via `Ecto.Multi`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Tenants
  alias Loopctl.Webhooks.Webhook
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.Workers.WebhookDeliveryWorker

  @doc """
  Creates a new webhook subscription for a tenant.

  Generates a cryptographically random signing secret, encrypts it via
  Cloak, and returns the raw secret once in the response. The tenant's
  `max_webhooks` setting is enforced.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with `url`, `events`, optional `project_id`
  - `opts` -- keyword list with `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %{webhook: %Webhook{}, signing_secret: raw_secret}}` on success
  - `{:error, :webhook_limit_reached}` if max webhooks exceeded
  - `{:error, changeset}` on validation failure
  """
  @spec create_webhook(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{webhook: Webhook.t(), signing_secret: String.t()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def create_webhook(tenant_id, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    with {:ok, tenant} <- Tenants.get_tenant(tenant_id),
         :ok <- check_webhook_limit(tenant_id, tenant) do
      raw_secret = generate_signing_secret()

      changeset =
        %Webhook{
          tenant_id: tenant_id,
          signing_secret_encrypted: raw_secret
        }
        |> Webhook.create_changeset(attrs)

      multi =
        Multi.new()
        |> Multi.insert(:webhook, changeset)
        |> Audit.log_in_multi(:audit, fn %{webhook: webhook} ->
          %{
            tenant_id: tenant_id,
            entity_type: "webhook",
            entity_id: webhook.id,
            action: "created",
            actor_type: "api_key",
            actor_id: actor_id,
            actor_label: actor_label,
            new_state: %{
              "url" => webhook.url,
              "events" => webhook.events,
              "project_id" => webhook.project_id,
              "active" => webhook.active
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{webhook: webhook}} ->
          {:ok, %{webhook: webhook, signing_secret: raw_secret}}

        {:error, :webhook, changeset, _} ->
          {:error, changeset}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Lists webhook subscriptions for a tenant with page-based pagination.

  ## Options

  - `:page` -- page number (default 1)
  - `:page_size` -- webhooks per page (default 20, max 100)

  ## Returns

  `{:ok, %{data: [%Webhook{}], total: integer, page: integer, page_size: integer}}`
  """
  @spec list_webhooks(Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [Webhook.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
  def list_webhooks(tenant_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = opts |> Keyword.get(:page_size, 20) |> max(1) |> min(100)
    offset = (page - 1) * page_size

    base_query =
      Webhook
      |> where([w], w.tenant_id == ^tenant_id)

    total = AdminRepo.aggregate(base_query, :count, :id)

    webhooks =
      base_query
      |> order_by([w], desc: w.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> AdminRepo.all()

    {:ok, %{data: webhooks, total: total, page: page, page_size: page_size}}
  end

  @doc """
  Gets a webhook by ID, scoped to a tenant.

  ## Returns

  - `{:ok, %Webhook{}}` if found
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_webhook(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Webhook.t()} | {:error, :not_found}
  def get_webhook(tenant_id, webhook_id) do
    case AdminRepo.get_by(Webhook, id: webhook_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      webhook -> {:ok, webhook}
    end
  end

  @doc """
  Updates a webhook subscription.

  Updatable fields: url, events, project_id, active.
  Reactivating (setting active=true) resets consecutive_failures to 0.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `webhook_id` -- the webhook UUID
  - `attrs` -- map of fields to update
  - `opts` -- keyword list with `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Webhook{}}` on success
  - `{:error, :not_found}` if webhook not found
  - `{:error, changeset}` on validation failure
  """
  @spec update_webhook(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Webhook.t()} | {:error, atom() | Ecto.Changeset.t()}
  def update_webhook(tenant_id, webhook_id, attrs, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    with {:ok, webhook} <- get_webhook(tenant_id, webhook_id) do
      old_state = %{
        "url" => webhook.url,
        "events" => webhook.events,
        "project_id" => webhook.project_id,
        "active" => webhook.active
      }

      changeset = Webhook.update_changeset(webhook, attrs)

      multi =
        Multi.new()
        |> Multi.update(:webhook, changeset)
        |> Audit.log_in_multi(:audit, fn %{webhook: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "webhook",
            entity_id: updated.id,
            action: "updated",
            actor_type: "api_key",
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: old_state,
            new_state: %{
              "url" => updated.url,
              "events" => updated.events,
              "project_id" => updated.project_id,
              "active" => updated.active
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{webhook: updated}} -> {:ok, updated}
        {:error, :webhook, changeset, _} -> {:error, changeset}
      end
    end
  end

  @doc """
  Deletes a webhook and all its pending webhook events.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `webhook_id` -- the webhook UUID
  - `opts` -- keyword list with `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Webhook{}}` on success
  - `{:error, :not_found}` if webhook not found
  """
  @spec delete_webhook(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Webhook.t()} | {:error, :not_found}
  def delete_webhook(tenant_id, webhook_id, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    with {:ok, webhook} <- get_webhook(tenant_id, webhook_id) do
      multi =
        Multi.new()
        |> Multi.delete(:webhook, webhook)
        |> Audit.log_in_multi(:audit, fn _changes ->
          %{
            tenant_id: tenant_id,
            entity_type: "webhook",
            entity_id: webhook.id,
            action: "deleted",
            actor_type: "api_key",
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: %{
              "url" => webhook.url,
              "events" => webhook.events,
              "project_id" => webhook.project_id,
              "active" => webhook.active
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{webhook: deleted}} -> {:ok, deleted}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Counts webhooks for a tenant.
  """
  @spec count_webhooks(Ecto.UUID.t()) :: non_neg_integer()
  def count_webhooks(tenant_id) do
    Webhook
    |> where([w], w.tenant_id == ^tenant_id)
    |> AdminRepo.aggregate(:count, :id)
  end

  @doc """
  Sends a test event to a webhook endpoint.

  Creates a webhook_event with event_type='webhook.test' and enqueues
  it for delivery via the Oban worker. Works even if the webhook is
  inactive (test events bypass the active check in the delivery worker).

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `webhook_id` -- the webhook UUID

  ## Returns

  - `{:ok, %WebhookEvent{}}` on success
  - `{:error, :not_found}` if webhook not found
  """
  @spec test_webhook(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, WebhookEvent.t()} | {:error, :not_found}
  def test_webhook(tenant_id, webhook_id) do
    with {:ok, webhook} <- get_webhook(tenant_id, webhook_id) do
      now = DateTime.utc_now()

      changeset =
        %WebhookEvent{
          tenant_id: tenant_id,
          webhook_id: webhook.id
        }
        |> WebhookEvent.create_changeset(%{
          event_type: "webhook.test",
          payload: %{
            "event" => "webhook.test",
            "data" => %{
              "message" => "This is a test event",
              "webhook_id" => webhook.id
            },
            "timestamp" => DateTime.to_iso8601(now)
          }
        })

      multi =
        Multi.new()
        |> Multi.insert(:event, changeset)
        |> Multi.run(:oban_job, fn _repo, %{event: event} ->
          WebhookDeliveryWorker.new(%{
            webhook_event_id: event.id,
            tenant_id: tenant_id
          })
          |> Oban.insert()
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{event: event}} -> {:ok, event}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Lists recent delivery attempts (webhook events) for a webhook.

  Returns events ordered by inserted_at descending. Does NOT include
  the full payload to reduce response size.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `webhook_id` -- the webhook UUID
  - `opts` -- keyword list with `:page` (default 1), `:page_size` (default 25, max 100)

  ## Returns

  `{:ok, %{data: [%WebhookEvent{}], total: integer, page: integer, page_size: integer}}`
  or `{:error, :not_found}` if webhook not found.
  """
  @spec list_deliveries(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             data: [WebhookEvent.t()],
             total: non_neg_integer(),
             page: pos_integer(),
             page_size: pos_integer()
           }}
          | {:error, :not_found}
  def list_deliveries(tenant_id, webhook_id, opts \\ []) do
    with {:ok, _webhook} <- get_webhook(tenant_id, webhook_id) do
      page = max(Keyword.get(opts, :page, 1), 1)
      page_size = opts |> Keyword.get(:page_size, 25) |> max(1) |> min(100)
      offset = (page - 1) * page_size

      base_query =
        WebhookEvent
        |> where([e], e.tenant_id == ^tenant_id and e.webhook_id == ^webhook_id)

      total = AdminRepo.aggregate(base_query, :count, :id)

      events =
        base_query
        |> order_by([e], desc: e.inserted_at)
        |> limit(^page_size)
        |> offset(^offset)
        |> AdminRepo.all()

      {:ok, %{data: events, total: total, page: page, page_size: page_size}}
    end
  end

  @doc """
  Checks if a webhook should be auto-disabled based on consecutive failures.

  Called by the delivery worker after exhaustion. Compares the webhook's
  consecutive_failures against the tenant's configurable threshold.
  If exceeded, sets active=false and logs an audit entry.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `webhook` -- the webhook struct with updated consecutive_failures

  ## Returns

  - `{:ok, :disabled}` if auto-disabled
  - `{:ok, :still_active}` if under threshold
  """
  @spec maybe_auto_disable(Ecto.UUID.t(), Webhook.t()) ::
          {:ok, :disabled | :still_active}
  def maybe_auto_disable(tenant_id, webhook) do
    with {:ok, tenant} <- Tenants.get_tenant(tenant_id) do
      threshold =
        Tenants.get_tenant_settings(tenant, "webhook_max_consecutive_failures", 10)

      if webhook.consecutive_failures >= threshold do
        do_auto_disable(tenant_id, webhook, threshold)
      else
        {:ok, :still_active}
      end
    end
  end

  defp do_auto_disable(tenant_id, webhook, threshold) do
    multi =
      Multi.new()
      |> Multi.update(
        :disable_webhook,
        Ecto.Changeset.change(webhook, %{active: false})
      )
      |> Audit.log_in_multi(:audit, fn _changes ->
        %{
          tenant_id: tenant_id,
          entity_type: "webhook",
          entity_id: webhook.id,
          action: "webhook_auto_disabled",
          actor_type: "system",
          actor_id: nil,
          actor_label: "system:auto_disable",
          new_state: %{
            "consecutive_failures" => webhook.consecutive_failures,
            "threshold" => threshold
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, _} -> {:ok, :disabled}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  # --- Private helpers ---

  defp generate_signing_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  defp check_webhook_limit(tenant_id, tenant) do
    max_webhooks = Tenants.get_tenant_settings(tenant, "max_webhooks", 10)
    current_count = count_webhooks(tenant_id)

    if current_count >= max_webhooks do
      {:error, :webhook_limit_reached}
    else
      :ok
    end
  end
end
