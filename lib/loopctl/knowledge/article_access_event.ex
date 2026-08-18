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
  - `"drill"` -- ANY article's body read via `knowledge_progressive_drill`, tenant-owned
    and system canonical alike (#572); a body read like `"get"`, split out only so the
    heat ranking cannot count the reads it caused itself (#569)

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

  # `"drill"` is a body read like `"get"`, split out ONLY so the heat index cannot rank on a
  # signal it generates itself (#569). `heat_index/2` orders on `"get"`, and the tool its own
  # `meta.drill` tells callers to use — `knowledge_progressive_drill` — recorded a `"get"`,
  # so an article gained heat from HAVING BEEN SHOWN by the index. EVERY drill records this
  # type, tenant-owned and system canonical alike (#572); the read is still recorded, it just
  # is not the signal the ranking consumes. Keep `"drill"` OUT of `@heat_read_access_types`
  # and IN anything asking "was a body delivered"
  # (`RetrievalMetrics.compute_followed_through/2`).
  #
  # This list and `Loopctl.Knowledge.Analytics`'s `@valid_access_types` are two allowlists over
  # one column and MUST move together, but they are NOT peers, and calling them both "the
  # enforcement" was wrong (#572). The ENFORCEMENT is `Analytics.record_access/6`'s guard
  # clause: every write reaches the DB through `do_record_sync/5`'s `AdminRepo.insert_all`,
  # which builds no changeset, so the `validate_inclusion` below never runs on a production
  # write — it covers only callers that construct a changeset directly. There is no DB CHECK
  # either. The drift test binding the two lists still earns its keep (a value in only one is
  # silently unwritable or silently unvalidated), but do not read this list as a gate.
  @access_types ~w(search get context index drill)

  # HOW an `origin_search_id` was established. Recorded rather than inferred at read time so
  # a consumer never mistakes an inference for an observation — `cross_key` is the injected
  # recall hook's shape (it searches under one key, the session reads under another) and is
  # PLAUSIBLE, not proof: two agents in one tenant can reach the same article independently.
  # `none` is not a failure — it is the agent going straight to an article by link or cited
  # id, which used to be indistinguishable from "surfaced and ignored". It is asserted only
  # where the absence of a surfacing row MEANS that: a `drill` nothing surfaced stays NULL,
  # because `progressive_index/3` records no surfacing row for the index that showed the stub.
  @origin_attributions ~w(same_key cross_key none)

  schema "article_access_events" do
    tenant_field()
    belongs_to :article, Loopctl.Knowledge.Article
    belongs_to :api_key, Loopctl.Auth.ApiKey
    belongs_to :project, Loopctl.Projects.Project
    belongs_to :story, Loopctl.WorkBreakdown.Story

    field :access_type, :string
    field :metadata, :map, default: %{}
    field :accessed_at, :utc_datetime_usec

    # Which search surfaced this article to the agent that then opened it, resolved
    # SERVER-SIDE at write time and never accepted from a caller — the same rule
    # `metadata["search_id"]` follows (#582), for the same reason: a forged origin lets an
    # agent manufacture follow-through for its own article. Both are nil on surfacing rows
    # (`search`, `index`) and on everything written before the column existed.
    field :origin_search_id, Ecto.UUID
    field :origin_attribution, :string

    # No timestamps() — accessed_at is the only timestamp.
  end

  @doc """
  Returns the list of valid `access_type` values.
  """
  @spec access_types() :: [String.t()]
  def access_types, do: @access_types

  @doc """
  Returns the list of valid `origin_attribution` values.

  Same caveat as `access_types/0`: the production write path is `insert_all` and builds no
  changeset, so this list is not a gate — `Analytics.resolve_origin/4` is the only writer,
  and the drift test binds the two.
  """
  @spec origin_attributions() :: [String.t()]
  def origin_attributions, do: @origin_attributions

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
    # `origin_search_id` / `origin_attribution` are deliberately NOT cast, for the same
    # reason `tenant_id` is not: they are resolved by the writer
    # (`Analytics.resolve_origin/5`), never supplied. Adding them here would give an API
    # caller a way to assert which search produced its own read — the forgery #582 closed
    # for `search_id`, and the self-inflating loop #567/#569 closed for the heat index.
    |> validate_required([:article_id, :api_key_id, :access_type, :accessed_at])
    |> validate_inclusion(:access_type, @access_types)
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:api_key_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:story_id)
  end
end
