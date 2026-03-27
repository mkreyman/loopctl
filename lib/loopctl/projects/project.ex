defmodule Loopctl.Projects.Project do
  @moduledoc """
  Schema for the `projects` table.

  Projects are the primary organizational unit for work tracking. Each
  project represents a codebase being developed by AI agents within a
  tenant. Projects have a unique slug within their tenant for URL-friendly
  references.

  ## Fields

  - `name` -- display name
  - `slug` -- unique within tenant (lowercase alphanumeric + hyphens, 2-63 chars)
  - `repo_url` -- GitHub/GitLab repository URL
  - `description` -- freeform text description
  - `tech_stack` -- e.g., "elixir/phoenix", "typescript/fastify"
  - `status` -- `:active` or `:archived`
  - `metadata` -- JSONB map for extensibility
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @statuses [:active, :archived]
  @slug_format ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :name,
             :slug,
             :repo_url,
             :description,
             :tech_stack,
             :status,
             :metadata,
             :inserted_at,
             :updated_at
           ]}

  schema "projects" do
    tenant_field()
    field :name, :string
    field :slug, :string
    field :repo_url, :string
    field :description, :string
    field :tech_stack, :string
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Changeset for creating a new project.

  The `tenant_id` is set programmatically, not via cast.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(project \\ %__MODULE__{}, attrs) do
    project
    |> cast(attrs, [:name, :slug, :repo_url, :description, :tech_stack, :metadata])
    |> validate_required([:name, :slug])
    |> validate_slug()
    |> validate_metadata()
    |> unique_constraint([:tenant_id, :slug],
      message: "has already been taken for this tenant"
    )
  end

  @doc """
  Changeset for updating an existing project.

  Slug cannot be changed after creation.
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :repo_url, :description, :tech_stack, :status, :metadata])
    |> validate_inclusion(:status, @statuses)
    |> validate_metadata()
  end

  @doc """
  Changeset for archiving a project (setting status to :archived).
  """
  @spec archive_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def archive_changeset(project) do
    change(project, status: :archived)
  end

  @doc """
  Returns the list of valid statuses.
  """
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  defp validate_slug(changeset) do
    changeset
    |> validate_format(:slug, @slug_format,
      message:
        "must be lowercase alphanumeric with hyphens, starting and ending with alphanumeric"
    )
    |> validate_length(:slug, min: 2, max: 63)
  end

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      if is_map(value) and not is_struct(value) do
        []
      else
        [metadata: "must be a map"]
      end
    end)
  end
end
