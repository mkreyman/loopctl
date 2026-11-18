defmodule Loopctl.Changes.PrReviewOutcome do
  @moduledoc """
  Schema for `pr_review_outcomes`: one merged pull request's parsed `## Review findings`
  section (US-50.4). Written only by `Loopctl.Changes.PrReviewOutcomes`; no field is cast from a
  request. `findings` and `unparsed` come from UNTRUSTED forge text and are never read as
  instructions.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "pr_review_outcomes" do
    tenant_field()
    field :source_id, :binary_id
    field :repo, :string
    field :pr_number, :integer
    field :merged_at, :utc_datetime_usec
    field :merge_sha, :string
    field :has_review_section, :boolean
    field :findings, {:array, :map}, default: []
    field :unparsed, {:array, :string}, default: []

    timestamps()
  end
end
