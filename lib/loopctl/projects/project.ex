defmodule Loopctl.Projects.Project do
  @moduledoc """
  Schema for the `projects` table.

  Projects are the primary organizational unit for work tracking. Each
  project represents a codebase being developed by AI agents within a
  tenant. Projects have a unique slug within their tenant for URL-friendly
  references.

  ## Fields

  - `name` -- display name
  - `slug` -- unique within tenant, archived projects included (lowercase alphanumeric,
    hyphens and underscores, 2-63 chars). A `kind: :kb` scope's slug can be changed;
    a work project's cannot.

  A `kind: :kb` scope is a repo's coordination channel, and its `name` must equal its
  `slug` (#1038): two strings made by two rules drifted apart on 17 of 29 projects.
  - `repo_url` -- GitHub/GitLab repository URL
  - `description` -- freeform text description
  - `tech_stack` -- e.g., "elixir/phoenix", "typescript/fastify"
  - `status` -- `:active` or `:archived`
  - `mission` -- optional project mission/goal statement that agents can
    cascade into story context (e.g., "Build the #1 AI note-taking app
    to $1M MRR"). Surfaces in get_story responses so every story carries
    the project's why without a separate fetch.
  - `metadata` -- JSONB map for extensibility
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @statuses [:active, :archived]
  @kinds [:work, :kb]
  # `_` is allowed so a repo channel's slug can be the repo basename verbatim
  # (`home_care_billing`), the same string its name carries (#1038).
  @slug_format ~r/^[a-z0-9][a-z0-9_-]*[a-z0-9]$/
  @mission_max_length 2_000

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
             :kind,
             :mission,
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
    # `:work` (default) carries the chain-of-custody surface; `:kb` is a knowledge-only
    # scope. Deliberately NOT in any `cast/3` list — it is set programmatically in
    # `Projects.create_project/3` (mirroring how `tenant_id` and `trust_tier` are kept
    # out of cast), so a request body can never elevate a `:kb` scope into a `:work` one.
    field :kind, Ecto.Enum, values: @kinds, default: :work
    field :mission, :string
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
    |> cast(attrs, [:name, :slug, :repo_url, :description, :tech_stack, :mission, :metadata])
    |> validate_required([:name, :slug])
    |> validate_slug()
    |> validate_kb_name_equals_slug()
    |> validate_mission()
    |> validate_metadata()
    |> slug_unique_constraint()
  end

  @doc """
  Changeset for updating an existing project.

  A work project's slug cannot be changed (a `slug` that differs is refused). A `kind: :kb`
  scope's slug can, so a repo channel can be aligned to its repo name (#1038); when only
  the slug changes, the name follows it, and a name that differs from the slug is refused.
  Status cannot be changed here: archiving and restoring are `archive_changeset/1` and
  `activate_changeset/1`, reached only through `Projects.archive_project/3` and
  `Projects.unarchive_project/3`, which carry the role gate, the `max_projects` cap and the
  audit action an ordinary edit does not.
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug, :repo_url, :description, :tech_stack, :mission, :metadata])
    |> validate_required([:name, :slug])
    |> validate_slug_change()
    |> validate_slug()
    |> name_follows_slug()
    |> validate_kb_name_equals_slug()
    |> validate_mission()
    |> validate_metadata()
    |> slug_unique_constraint()
  end

  defp slug_unique_constraint(changeset) do
    unique_constraint(changeset, [:tenant_id, :slug],
      message: "has already been taken for this tenant",
      error_key: :slug
    )
  end

  defp validate_slug_change(%{data: %{kind: :kb}} = changeset), do: changeset

  defp validate_slug_change(changeset) do
    if changed?(changeset, :slug),
      do: add_error(changeset, :slug, "cannot be changed on a work project"),
      else: changeset
  end

  # A kb scope renamed by slug alone keeps name == slug without the caller restating it.
  defp name_follows_slug(%{data: %{kind: :kb}} = changeset) do
    if changed?(changeset, :slug) and not changed?(changeset, :name),
      do: put_change(changeset, :name, get_field(changeset, :slug)),
      else: changeset
  end

  defp name_follows_slug(changeset), do: changeset

  defp validate_kb_name_equals_slug(%{data: %{kind: :kb}} = changeset) do
    name = get_field(changeset, :name)
    slug = get_field(changeset, :slug)

    if is_binary(name) and is_binary(slug) and name != slug,
      do: add_error(changeset, :name, "must equal the slug (#{slug}) for a kb scope"),
      else: changeset
  end

  defp validate_kb_name_equals_slug(changeset), do: changeset

  @doc """
  Changeset for archiving a project (setting status to :archived).
  """
  @spec archive_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def archive_changeset(project) do
    change(project, status: :archived)
  end

  @doc """
  Changeset for re-activating an archived project (setting status to :active).
  """
  @spec activate_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def activate_changeset(project) do
    change(project, status: :active)
  end

  @doc """
  Returns the list of valid statuses.
  """
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc """
  Returns the list of valid project kinds.
  """
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  defp validate_slug(changeset) do
    changeset
    |> validate_format(:slug, @slug_format,
      message:
        "must be lowercase alphanumeric with hyphens or underscores, starting and " <>
          "ending with alphanumeric"
    )
    |> validate_length(:slug, min: 2, max: 63)
  end

  defp validate_mission(changeset) do
    changeset
    |> update_change(:mission, fn
      nil -> nil
      value when is_binary(value) -> String.trim(value)
    end)
    |> update_change(:mission, fn
      "" -> nil
      value -> value
    end)
    |> validate_length(:mission, max: @mission_max_length)
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
