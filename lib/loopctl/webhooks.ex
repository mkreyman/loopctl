defmodule Loopctl.Webhooks do
  @moduledoc """
  Context module for webhook subscription management.

  Webhooks allow tenants to receive real-time push notifications when
  state changes occur in loopctl. Each webhook defines a delivery URL,
  a signing secret (encrypted via Cloak), and a list of event types.

  All operations are tenant-scoped via `tenant_id` and include audit
  logging via `Ecto.Multi`.

  ## Destinations are vetted at CONFIG TIME, not only at delivery time (US-41.5)

  AC-41.5.3: creating or updating a subscription whose destination is not local
  for an already-`local_only` scope is REJECTED here with a legible remediation,
  rather than accepted and silently blocked on every later delivery. The check
  needs tenant/DB state (the effective marking and the tenant's declarations), so
  it lives in the context rather than the changeset — but it runs BEFORE the
  `Ecto.Multi`, so nothing is persisted on rejection.

  It consults the SAME single egress policy the delivery path does
  (`Loopctl.Egress.webhook_destination_check/2` → `Loopctl.Egress.Policy`), with
  purpose `:webhook`. There is deliberately no second copy of the URL rules here.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Egress
  alias Loopctl.Egress.Scope
  alias Loopctl.Projects.Project
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

      base = %Webhook{tenant_id: tenant_id, signing_secret_encrypted: raw_secret}
      changeset = Webhook.create_changeset(base, attrs)

      prewarm_destination(tenant_id, changeset)

      multi =
        Multi.new()
        |> lock_egress_config(tenant_id)
        |> Multi.run(:changeset, fn _repo, _changes ->
          validated_changeset(changeset, tenant_id)
        end)
        |> Multi.insert(:webhook, & &1.changeset)
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

        {:error, step, %Ecto.Changeset{} = changeset, _} when step in [:changeset, :webhook] ->
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
  Every subscription `Loopctl.Egress` must classify, oldest first.

  The ONE reader the egress guard uses, so webhook persistence stays behind THIS
  context (US-41.5 review). `Loopctl.Egress` previously built its own queries
  against `Loopctl.Webhooks.Webhook` for both the `local_only` pre-flight and the
  posture report, which put the tenant-scoping predicate for webhooks in two
  contexts: a later change to webhook visibility (soft delete, an archived flag,
  a project-scoping rule) would have silently missed the guard and the report —
  precisely the report/guard divergence the posture exists to prevent.

  `project_id` selects the MARKING's coverage, not the delivery scope:

    * `:all` — every subscription (a TENANT-scope marking covers all of them).
    * a project UUID — only that project's subscriptions. A project marking
      cannot cover a tenant-wide (project-less) subscription, whose delivery
      scope it does not narrow (AC-41.4.2, most-restrictive-wins).

  `:limit` bounds the number of rows an egress caller will classify (each
  classification can cost a DNS resolve).
  """
  @spec list_for_egress(Ecto.UUID.t(), Ecto.UUID.t() | :all, keyword()) :: [Webhook.t()]
  def list_for_egress(tenant_id, project_id \\ :all, opts \\ []) do
    Webhook
    |> where([w], w.tenant_id == ^tenant_id)
    |> egress_project_filter(project_id)
    |> order_by([w], asc: w.inserted_at)
    |> maybe_limit(Keyword.get(opts, :limit))
    |> AdminRepo.all()
  end

  defp egress_project_filter(query, :all), do: query

  defp egress_project_filter(query, project_id),
    do: where(query, [w], w.project_id == ^project_id)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, max) when is_integer(max), do: limit(query, ^max)

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

      prewarm_destination(tenant_id, changeset)

      multi =
        Multi.new()
        |> lock_egress_config(tenant_id)
        |> Multi.run(:changeset, fn _repo, _changes ->
          validated_changeset(changeset, tenant_id)
        end)
        |> Multi.update(:webhook, & &1.changeset)
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
        {:ok, %{webhook: updated}} ->
          {:ok, updated}

        {:error, step, %Ecto.Changeset{} = changeset, _} when step in [:changeset, :webhook] ->
          {:error, changeset}

        {:error, _step, reason, _changes} ->
          {:error, reason}
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

  # Serializes this write against a concurrent `Egress.enable_local_only/3` on the
  # same tenant (review fix). The AC-41.5.3 config-time check reads the MARKING
  # table, and the enable pre-flight reads the WEBHOOK table, so without a shared
  # lock a subscription created between the pre-flight snapshot and the marking
  # commit is neither refused here nor reported there — it is just silently
  # blocked at delivery. Both writers take this lock FIRST and run their check
  # inside it. See `Loopctl.Egress.lock_scope_config!/2`.
  defp lock_egress_config(multi, tenant_id) do
    Multi.run(multi, :egress_lock, fn repo, _changes ->
      {:ok, Egress.lock_scope_config!(repo, tenant_id)}
    end)
  end

  # Resolves and classifies the destination BEFORE the transaction opens, so the
  # config-time check inside the lock reads the pin cache instead of waiting on a
  # resolver (issue #624).
  #
  # WHAT THE IN-TRANSACTION PLACEMENT PROTECTS IS UNCHANGED. The race
  # `lock_egress_config/2` closes is between this write and a concurrent
  # `Egress.enable_local_only/3`: the thing that must be read inside the lock is
  # the tenant's MARKING, so that one of the two writers always observes the
  # other's committed state. The DESTINATION's address classification races
  # nothing — it is a property of the host, not of tenant configuration — so
  # hoisting it out costs no correctness. `validate_destination_locality/2` still
  # runs inside the lock and still makes the whole decision there; this only
  # arranges for its expensive half to be already done.
  #
  # It is a WARM, not a precondition: nothing depends on the entry still being
  # cached. An invalidation between the two points simply means the resolve
  # happens inside the lock as before.
  #
  # Why it matters: `AdminRepo` runs on a 3-connection pool
  # (`config/runtime.exs:190`), and `UrlGuard`'s resolver spends up to 3s per
  # family on a host that does not answer. Holding one of three BYPASSRLS
  # connections for that long — on a tenant-supplied hostname — puts the egress
  # guard's own marking lookups behind an attacker-influenced delay.
  defp prewarm_destination(tenant_id, changeset) do
    if changeset.valid? and egress_decision_changed?(changeset) do
      url = Ecto.Changeset.get_field(changeset, :url)
      project_id = Ecto.Changeset.get_field(changeset, :project_id)

      Egress.prewarm_webhook_destination(Scope.new(tenant_id, project_id), url)
    end

    :ok
  end

  # The two DB-dependent validations, in the order their errors should surface:
  # a `project_id` that is not this tenant's makes the egress SCOPE meaningless,
  # so it is settled before the destination is classified under that scope.
  #
  # Returns an `{:ok, changeset}` / `{:error, changeset}` pair because it runs as
  # a `Multi.run/3` step INSIDE the locked transaction — the DECISION must see the
  # marking under the lock. Its expensive half (resolve + classify) is warmed
  # before the transaction opens by `prewarm_destination/2`, so the connection is
  # normally held only for the cache read.
  defp validated_changeset(changeset, tenant_id) do
    validated =
      changeset
      |> validate_project_ownership(tenant_id)
      |> validate_destination_locality(tenant_id)

    if validated.valid?, do: {:ok, validated}, else: {:error, validated}
  end

  # `project_id` is cast from client input and its FK targets `projects.id`
  # ALONE, so another tenant's project satisfies the database — and writes go
  # through `AdminRepo`, which bypasses RLS. US-41.5 makes that load-bearing: the
  # delivery scope IS `Scope.new(webhook.tenant_id, webhook.project_id)`, so a
  # foreign `project_id` matches no marking of this tenant and side-steps a
  # project-scoped `local_only` marking without touching the audited, `:user`-
  # gated marking row (it also skews the pre-flight and the posture report, which
  # scope by the same field). Validated here rather than by a composite FK so the
  # caller gets a changeset error instead of a constraint violation, matching
  # what `LoopctlWeb.EgressController` already does for its own `project_id`.
  defp validate_project_ownership(%Ecto.Changeset{valid?: false} = changeset, _tenant_id),
    do: changeset

  defp validate_project_ownership(changeset, tenant_id) do
    # `get_field/2` (not `get_change/2`): an update that changes only the URL must
    # still be classified under a scope this tenant actually owns.
    case Ecto.Changeset.get_field(changeset, :project_id) do
      nil ->
        changeset

      project_id ->
        if project_of_tenant?(tenant_id, project_id) do
          changeset
        else
          Ecto.Changeset.add_error(
            changeset,
            :project_id,
            "does not belong to this tenant (or does not exist)"
          )
        end
    end
  end

  defp project_of_tenant?(tenant_id, project_id) do
    Project
    |> where([p], p.id == ^project_id and p.tenant_id == ^tenant_id)
    |> limit(1)
    |> AdminRepo.exists?()
  end

  # AC-41.5.3. Runs when the edit changes the EFFECTIVE EGRESS DECISION — the
  # destination url, the scope it is delivered under (`project_id`), or a
  # re-activation — AND the changeset is otherwise valid: classifying a URL that
  # already failed `validate_egress/1` would replace a precise scheme/DNS error
  # with a locality one.
  #
  # It deliberately does NOT run on an edit that touches neither (e.g.
  # `active: false`, `events`), so a subscription that predates the marking stays
  # editable — including by the very edit that fixes it.
  #
  # REVIEW FIX: keying only on a `:url` change left the check bypassable. The
  # egress scope is `Scope.new(tenant_id, project_id)`, so a PATCH carrying only
  # `project_id` re-scoped a public destination under a `local_only` project and
  # was accepted — the "accepted, then silently blocked at delivery time" outcome
  # AC-41.5.3 exists to prevent. A `false -> true` re-activation is checked for
  # the same reason the pre-flight (AC-41.5.4) reports INACTIVE subscriptions:
  # re-activating one under an unchanged marking would silently produce a blocked
  # destination.
  defp validate_destination_locality(%Ecto.Changeset{valid?: false} = changeset, _tenant_id),
    do: changeset

  defp validate_destination_locality(changeset, tenant_id) do
    if egress_decision_changed?(changeset) do
      url = Ecto.Changeset.get_field(changeset, :url)
      project_id = Ecto.Changeset.get_field(changeset, :project_id)
      scope = Scope.new(tenant_id, project_id)

      case Egress.webhook_destination_check(scope, url) do
        :ok ->
          changeset

        {:error, {_verdict, remediation}} ->
          Ecto.Changeset.add_error(changeset, :url, remediation)
      end
    else
      changeset
    end
  end

  # `Map.has_key?/2` on `changes` rather than `get_change/2` for `:project_id`:
  # UNSETTING the project (`project_id: nil`) widens a project-scoped delivery to
  # the TENANT scope and must be classified too, and `get_change/2` returns nil
  # for both "changed to nil" and "not changed".
  defp egress_decision_changed?(changeset) do
    not is_nil(Ecto.Changeset.get_change(changeset, :url)) or
      Map.has_key?(changeset.changes, :project_id) or
      Ecto.Changeset.get_change(changeset, :active) == true
  end

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
