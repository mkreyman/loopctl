defmodule Loopctl.Knowledge.ArticleAccessEvent do
  @moduledoc """
  Schema for the `article_access_events` table.

  Article access events are immutable facts that record every read access
  to an article in the knowledge wiki. They power the analytics endpoints
  that surface which articles agents actually use, which agents read what,
  and which articles are dead weight.

  ## Access types

  - `"search"` -- recorded for top-N article ids returned by search results
  - `"get"` -- recorded for direct GET /articles/:id reads
  - `"context"` -- recorded for each article returned by GET /knowledge/context
  - `"index"` -- reserved (currently NOT recorded; index listings are too noisy)

  ## Fields

  - `tenant_id` -- the tenant that owns the article and the api_key
  - `article_id` -- the article that was accessed
  - `api_key_id` -- the api_key (and therefore the agent identity) that accessed it
  - `project_id` -- optional project attribution for the read (nullable)
  - `story_id` -- optional story attribution for the read (nullable)
  - `access_type` -- one of the access types above
  - `metadata` -- free-form context (e.g., search query, rank, score)
  - `accessed_at` -- when the access happened (microsecond precision)

  Access events are immutable: there are no updates and no `updated_at`
  column. Only `accessed_at` is stored.

  ## Attribution

  `project_id` and `story_id` are reporting dimensions added by US-25.1.
  They record the work context the caller was in at the time of the read.
  Both are optional so rows written before attribution existed remain valid
  and callers without context can still record reads.

  Neither column is referenced in any RLS predicate — `tenant_id` remains
  the sole isolation boundary. Cross-tenant attribution attempts are
  rejected by the context layer before the insert.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @access_types ~w(search get context index)

  schema "article_access_events" do
    tenant_field()
    belongs_to :article, Loopctl.Knowledge.Article
    belongs_to :api_key, Loopctl.Auth.ApiKey
    belongs_to :project, Loopctl.Projects.Project
    belongs_to :story, Loopctl.WorkBreakdown.Story

    field :access_type, :string
    field :metadata, :map, default: %{}
    field :accessed_at, :utc_datetime_usec

    # No timestamps() — accessed_at is the only timestamp.
  end

  @doc """
  Returns the list of valid `access_type` values.
  """
  @spec access_types() :: [String.t()]
  def access_types, do: @access_types

  @doc """
  Changeset for creating a new article access event.

  `tenant_id` is set programmatically and must not appear in attrs.
  The four positional fields (article_id, api_key_id, access_type, accessed_at)
  are required; metadata, project_id, and story_id are optional.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(struct \\ %__MODULE__{}, attrs) do
    struct
    |> cast(attrs, [
      :article_id,
      :api_key_id,
      :project_id,
      :story_id,
      :access_type,
      :metadata,
      :accessed_at
    ])
    |> validate_required([:article_id, :api_key_id, :access_type, :accessed_at])
    |> validate_inclusion(:access_type, @access_types)
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:api_key_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:story_id)
  end
end
