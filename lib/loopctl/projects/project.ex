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
    hyphens and underscores, 2-63 chars). It can be changed, so a repo's channel can
    be aligned to the repo name.

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

  Any project's slug can be changed, so a repo channel (a kb scope or a work project) can be
  aligned to its repo name (#1038). When the request carries no name and the stored name
  equals the stored slug, the name follows the new slug; a name that was never the slug is
  left alone. A kb name is otherwise held to the rule `create_changeset/2` applies (see
  `fold/1`).
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
    |> validate_slug()
    |> name_follows_slug(name_supplied?(attrs))
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

  # Whether the CALLER sent a name, not whether cast saw a change: a name equal to the
  # stored one casts as no change, and must still be judged rather than overwritten.
  defp name_supplied?(attrs), do: Map.has_key?(attrs, :name) or Map.has_key?(attrs, "name")

  # On a slug-only rename the name follows for a kb scope (always: its name is its slug, and a
  # legacy kb row whose name drifted is realigned rather than refused) and for a work project
  # whose name IS its slug. A work project with a display name keeps it.
  defp name_follows_slug(%{data: %{kind: :kb}} = changeset, false = _supplied),
    do: follow_slug(changeset)

  defp name_follows_slug(%{data: %{name: same, slug: same}} = changeset, false = _supplied),
    do: follow_slug(changeset)

  defp name_follows_slug(changeset, _name_supplied), do: changeset

  defp follow_slug(changeset) do
    if changed?(changeset, :slug),
      do: put_change(changeset, :name, get_field(changeset, :slug)),
      else: changeset
  end

  # A kb scope's name is its slug. A name that is the same string up to case and separators
  # (`home_care_billing` for slug `home-care-billing`, what MCP clients before 3.13 send) is
  # STORED as the slug rather than refused, so an older client still gets a channel; a name
  # that is a different string is refused.
  defp validate_kb_name_equals_slug(%{data: %{kind: :kb}} = changeset) do
    name = get_field(changeset, :name)
    slug = get_field(changeset, :slug)

    cond do
      not (is_binary(name) and is_binary(slug)) or name == slug ->
        changeset

      fold(name) == fold(slug) ->
        put_change(changeset, :name, slug)

      true ->
        add_error(changeset, :name, "must equal the slug (#{slug}) for a kb scope")
    end
  end

  defp validate_kb_name_equals_slug(changeset), do: changeset

  @doc """
  The FOLDED form of a slug, name or repo directory: trimmed, lowercased, every run of
  non-alphanumerics one `-`. `home_care_billing`, `Home-Care-Billing` and
  `home-care-billing` fold to the same string.
  """
  @spec fold(String.t()) :: String.t()
  def fold(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

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
