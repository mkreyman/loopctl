defmodule Loopctl.Delivery.ClaimRoute do
  @moduledoc """
  The route of an INTERACTIVE claim (US-45.9): the mode, base branch and thread branch its
  story's intake source named when a session claimed the story itself, with no runner
  placement. Written once, in `Loopctl.Delivery.InteractiveClaims`, and read only through
  `Loopctl.Runners.DispatchLedger.route_rows_query/0`, beside the routes placements record on
  the dispatch ledger.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "claim_routes" do
    field :tenant_id, :binary_id
    field :story_id, :binary_id
    field :claim_epoch, :integer
    field :mode, :string
    field :base_branch, :string
    field :branch, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
