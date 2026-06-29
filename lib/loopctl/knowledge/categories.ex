defmodule Loopctl.Knowledge.Categories do
  @moduledoc """
  Single source of truth for knowledge-article categories.

  Before this module the category list was duplicated in six places (the
  `Article` schema, both LLM extractor prompts + their `@valid_categories`
  guards, and two ingestion workers), which silently drifts. Everything now
  derives from here.

  ## Taxonomy (US — second-brain taxonomy expansion)

  **Active** categories — what new articles should be classified as:

  - `pattern`   — a reusable solution *shape*: how this kind of problem is
    generally solved (the structure, not the steps).
  - `decision`  — a specific choice that was made and *why* (ADR-style):
    options considered, tradeoff, the call.
  - `finding`   — an empirical discovery: a gotcha, a measured result, the
    outcome of an investigation ("X turned out to be true").
  - `reference` — factual lookup material: a spec, an API shape, a pointer to
    an external resource. Stable, not opinionated.
  - `playbook`  — a concrete, ordered *procedure* to accomplish a task (the
    steps), as opposed to `pattern` (the shape).
  - `insight`   — a durable principle or mental model that generalizes beyond
    one situation (the "why" that keeps paying off).
  - `entity`    — a person, company, tool, or product. The graph backbone —
    the nodes other articles reference.
  - `idea`      — a venture, opportunity, or thing to build/try.
  - `quote`     — a notable verbatim quote worth preserving, with attribution.
  - `question`  — an open question or known-unknown to investigate later.

  **Retired** categories — still valid in the DB so existing rows load and the
  reclassification backfill can read them, but new content should NOT use them:

  - `convention` — a team/project norm. Being reclassified into
    `pattern`/`playbook`/`insight`; will be dropped once the 77k backfill
    completes.

  Keeping a retired value in the enum (rather than deleting it) is deliberate:
  the `category` column is a plain string and ~13% of the corpus is currently
  `convention`; dropping the enum value before the backfill would make every
  one of those rows fail to load.
  """

  @active [
    :pattern,
    :decision,
    :finding,
    :reference,
    :playbook,
    :insight,
    :entity,
    :idea,
    :quote,
    :question
  ]

  @retired [:convention]

  @definitions %{
    pattern: "a reusable solution shape (how this kind of problem is generally solved)",
    decision: "a specific choice that was made and why (ADR-style: options, tradeoff, the call)",
    finding:
      "an empirical discovery — a gotcha, a measured result, the outcome of an investigation",
    reference:
      "factual lookup material — a spec, an API shape, a pointer to an external resource",
    playbook: "a concrete, ordered procedure to accomplish a task (the steps, not the shape)",
    insight: "a durable principle or mental model that generalizes beyond one situation",
    entity: "a person, company, tool, or product (the graph backbone other articles reference)",
    idea: "a venture, opportunity, or thing to build or try",
    quote: "a notable verbatim quote worth preserving, with attribution",
    question: "an open question or known-unknown to investigate later"
  }

  @doc "All categories valid in the database (active + retired). Use for enum/validation."
  @spec all() :: [atom()]
  def all, do: @active ++ @retired

  @doc "Active categories — what new content should be classified as (excludes retired)."
  @spec active() :: [atom()]
  def active, do: @active

  @doc "Retired categories — valid in the DB but not for new content."
  @spec retired() :: [atom()]
  def retired, do: @retired

  @doc "All categories as lowercase strings (active + retired)."
  @spec all_strings() :: [String.t()]
  def all_strings, do: Enum.map(all(), &Atom.to_string/1)

  @doc "Active categories as lowercase strings."
  @spec active_strings() :: [String.t()]
  def active_strings, do: Enum.map(@active, &Atom.to_string/1)

  @doc "One-line definition for an active category (nil for unknown/retired)."
  @spec definition(atom()) :: String.t() | nil
  def definition(category), do: Map.get(@definitions, category)

  @doc """
  A prompt fragment listing the active categories with their definitions, for
  use in LLM extraction/classification prompts so new articles use the full
  taxonomy. Retired categories are intentionally excluded so the model never
  emits them for new content.
  """
  @spec prompt_fragment() :: String.t()
  def prompt_fragment do
    Enum.map_join(@active, "; ", fn cat -> "#{cat} (#{Map.fetch!(@definitions, cat)})" end)
  end
end
