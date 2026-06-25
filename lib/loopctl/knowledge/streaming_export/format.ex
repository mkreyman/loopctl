defmodule Loopctl.Knowledge.StreamingExport.Format do
  @moduledoc """
  The pluggable per-format contract for the streaming knowledge export
  (US-27.16). Both the Obsidian and OKF exports reduce to "iterate published
  articles → emit a file per article, plus a cheap index"; this behaviour is the
  only thing that differs between them, so the streaming core
  (`Loopctl.Knowledge.StreamingExport`) is shared.

  An implementation is a stateless module: given an article (with its bounded link
  list already preloaded by the core) it returns the archive entries for THAT
  article; given a cheap per-category aggregate (no bodies loaded) it returns the
  index/prelude entries. The core never materializes the whole corpus — it calls
  `article_entries/2` one article at a time as it walks the keyset, and calls
  `index_entries/1` exactly once from a `GROUP BY` aggregate.
  """

  alias Loopctl.Knowledge.Article

  @typedoc "An archive entry: a POSIX path and its file contents."
  @type entry :: {path :: String.t(), content :: iodata()}

  @typedoc """
  Per-article render context the core threads in. `:links` is the BOUNDED list of
  this article's links (already capped by the core so a dense hub can't fan out
  into one giant entry — AC-27.16.3), each `%{direction, relationship_type, title,
  status, path}` describing one neighbor.
  """
  @type render_ctx :: %{
          optional(:links) => [map()],
          optional(:project_id) => Ecto.UUID.t() | nil,
          optional(atom()) => term()
        }

  @typedoc """
  A cheap per-category aggregate row: `%{category: atom_or_string, count:
  non_neg_integer}`. Built with a `GROUP BY` so `index_entries/1` never loads a
  body to render the index (AC-27.16 `_index.md` requirement).
  """
  @type category_aggregate :: [%{category: term(), count: non_neg_integer()}]

  @doc """
  Archive entries for one article. Usually a single `{path, content}` for the
  article's markdown file; an impl MAY return more than one (or `[]`).
  """
  @callback article_entries(Article.t(), render_ctx()) :: [entry()]

  @doc """
  Index/prelude entries (e.g. `_index.md`, `index.md`, `log.md`), built ONLY from
  the cheap per-category aggregate — no article bodies. Returns `[]` if the format
  has no index.
  """
  @callback index_entries(category_aggregate()) :: [entry()]

  @doc """
  Whether the index entries should be emitted BEFORE the article entries (a tar is
  forward-only). Defaults via the core to `true` when the impl doesn't care.
  """
  @callback index_position() :: :prelude | :postlude
end
