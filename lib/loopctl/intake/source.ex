defmodule Loopctl.Intake.Source do
  @moduledoc """
  Schema for the `intake_sources` table — one GitHub repository bound to one work project
  (issue #803).

  A source is ADDRESSED by its id: GitHub posts to `/api/v1/intake/github/:source_id`, so
  the tenant is resolved from the URL, never from the payload. The payload's
  `repository.full_name` must then equal `repo_full_name` (case-insensitively, as GitHub
  names are) or the delivery is refused.

  `webhook_secret` is the HMAC key GitHub signs deliveries with. It is generated
  server-side, encrypted at rest (`Loopctl.Vault.Binary`, AES-256-GCM), returned once at
  creation and never serialised again.

  ## Trust boundary

  `tenant_id`, `project_id`, `webhook_secret` and `revoked_at` are set programmatically in
  `Loopctl.Intake`, never via `cast/3`. `repo_full_name` is the only cast field.

  ## Isolation

  `AdminRepo` plus an explicit `tenant_id` predicate in every `Loopctl.Intake` query, the
  convention `Loopctl.Runners` follows. The one cross-tenant read is the delivery lookup
  by id, which has no tenant yet and resolves it from the row. RLS is ENABLED on the table
  as defense-in-depth.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  # GitHub owner: alphanumeric or hyphen, starting alphanumeric, at most 39. Repository:
  # letters, digits, '.', '_' or '-', at most 100. Mirrored by `intake_sources_repo_shape`.
  @repo_format ~r/^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/

  @derive {Jason.Encoder,
           only: [
             :id,
             :project_id,
             :repo_full_name,
             :target_epic_id,
             :revoked_at,
             :inserted_at,
             :updated_at
           ]}

  schema "intake_sources" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project

    # WHERE A TRIAGED STORY LANDS (#803 §4). A story requires an epic and this source only
    # knows its project, so without it the worker that turns a reported issue into a story
    # has nowhere to put it. NULLABLE: a source enrolled before the field existed keeps
    # working, and a record from a source that names no epic is ESCALATED to a human rather
    # than landing in one chosen for it. Unset means the question has not been answered,
    # which is not the same as any answer loopctl could invent.
    belongs_to :target_epic, Loopctl.WorkBreakdown.Epic
    field :repo_full_name, :string
    field :webhook_secret, Loopctl.Vault.Binary, redact: true
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The `owner/name` format a source's repository must have."
  @spec repo_format() :: Regex.t()
  def repo_format, do: @repo_format

  @doc """
  Changeset for creating a source. `tenant_id`, `project_id` and `webhook_secret` must
  already be set on the struct.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = source, attrs) do
    source
    |> cast(attrs, [:repo_full_name])
    |> validate_required([:repo_full_name])
    |> validate_format(:repo_full_name, @repo_format, message: "must be owner/name")
    |> check_constraint(:repo_full_name, name: :intake_sources_repo_shape)
    |> unique_constraint(:repo_full_name,
      name: :intake_sources_active_repo_uidx,
      message: "an active intake source already binds this repository"
    )
    |> foreign_key_constraint(:project_id)
  end

  @doc "Changeset that revokes a source."
  @spec revoke_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def revoke_changeset(%__MODULE__{} = source, now), do: change(source, revoked_at: now)
end
