defmodule Loopctl.Webhooks.Webhook do
  @moduledoc """
  Schema for the `webhooks` table -- tenant-configured outbound event subscriptions.

  Each webhook defines a delivery URL, a list of event types to subscribe to,
  and an optional project scope. The signing secret is encrypted at rest via
  Cloak (AES-256-GCM) and only returned once on creation.

  ## Fields

  - `url` -- HTTPS delivery target URL
  - `signing_secret_encrypted` -- Cloak-encrypted HMAC signing secret
  - `events` -- list of event type strings to subscribe to
  - `project_id` -- optional FK; NULL means all projects
  - `active` -- whether the webhook is enabled for delivery
  - `consecutive_failures` -- tracks exhausted deliveries for auto-disable
  - `last_delivery_at` -- timestamp of last successful delivery
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @valid_event_types ~w(
    story.status_changed
    story.verified
    story.rejected
    story.auto_reset
    story.force_unclaimed
    story.review_requested
    story.review_completed
    epic.completed
    artifact.reported
    agent.registered
    project.imported
    webhook.test
    token.budget_warning
    token.budget_exceeded
    token.anomaly_detected
    article.created
    article.updated
    article.archived
    article.superseded
    article_link.created
    article_link.deleted
  )

  @doc """
  Returns the list of valid event types for webhook subscriptions.
  """
  @spec valid_event_types() :: [String.t()]
  def valid_event_types, do: @valid_event_types

  schema "webhooks" do
    tenant_field()
    field :url, :string
    field :signing_secret_encrypted, Loopctl.Vault.Binary
    field :events, {:array, :string}, default: []

    belongs_to :project, Loopctl.Projects.Project, type: :binary_id

    field :active, :boolean, default: true
    field :consecutive_failures, :integer, default: 0
    field :last_delivery_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for creating a new webhook.

  The `signing_secret_encrypted` and `tenant_id` are set programmatically.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(webhook \\ %__MODULE__{}, attrs) do
    webhook
    |> cast(attrs, [:url, :events, :project_id])
    |> validate_required([:url, :events])
    |> validate_url()
    |> validate_events()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:project_id)
  end

  @doc """
  Changeset for updating an existing webhook.

  Updatable fields: url, events, project_id, active.
  Signing secret is NOT updatable.
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:url, :events, :project_id, :active])
    |> validate_url()
    |> validate_events()
    |> maybe_reset_failures()
    |> foreign_key_constraint(:project_id)
  end

  @private_ip_prefixes ~w(
    10.
    172.16.
    172.17.
    172.18.
    172.19.
    172.20.
    172.21.
    172.22.
    172.23.
    172.24.
    172.25.
    172.26.
    172.27.
    172.28.
    172.29.
    172.30.
    172.31.
    192.168.
    169.254.
    127.
  )

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      uri = URI.parse(url)

      cond do
        uri.scheme not in ["https", "http"] ->
          [url: "must use HTTPS or HTTP scheme"]

        is_nil(uri.host) or uri.host == "" ->
          [url: "must have a valid host"]

        private_host?(uri.host) ->
          [url: "must not target a private or loopback address"]

        true ->
          []
      end
    end)
  end

  defp private_host?(host) do
    normalized = String.downcase(host)

    normalized in ["localhost", "::1"] or
      Enum.any?(@private_ip_prefixes, &String.starts_with?(normalized, &1))
  end

  defp validate_events(changeset) do
    events = get_field(changeset, :events)

    cond do
      is_nil(events) or events == [] ->
        add_error(changeset, :events, "must contain at least one event type")

      is_list(events) ->
        invalid = Enum.reject(events, &(&1 in @valid_event_types))

        if invalid == [] do
          changeset
        else
          add_error(
            changeset,
            :events,
            "contains invalid event types: #{Enum.join(invalid, ", ")}"
          )
        end

      true ->
        changeset
    end
  end

  # When reactivating (active changes from false to true), reset consecutive_failures
  defp maybe_reset_failures(changeset) do
    case get_change(changeset, :active) do
      true ->
        put_change(changeset, :consecutive_failures, 0)

      _ ->
        changeset
    end
  end
end
