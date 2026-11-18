defmodule Loopctl.Changes.ReviewDispatch do
  @moduledoc """
  Schema for `chg_review_dispatches`: one review dispatch an intake source minted under its chg
  root for one `(change_id, revision)` (US-50.3). Written only by
  `Loopctl.Changes.ReviewDispatches`; no field is cast from a request.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "chg_review_dispatches" do
    tenant_field()
    field :source_id, :binary_id
    field :repo, :string
    field :change_id, :string
    field :revision, :integer
    field :dispatch_id, :binary_id

    timestamps(updated_at: false)
  end
end
