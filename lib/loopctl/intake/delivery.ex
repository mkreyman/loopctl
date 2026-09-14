defmodule Loopctl.Intake.Delivery do
  @moduledoc """
  Schema for the `intake_deliveries` table — one row per GitHub webhook delivery an intake
  source accepted (issue #803).

  `(source_id, github_delivery_id)` is unique, and that index is the idempotency key: a
  replayed or redelivered `X-GitHub-Delivery` inserts nothing, so it changes nothing.
  Rows are written by `Loopctl.Intake` with `insert_all/3` and read by tests and
  operators; there is no changeset.

  `payload_sha256` is the digest of the exact bytes the signature covered. No payload
  text is stored here.

  Rows are deleted past a tenant's window by `Loopctl.Workers.DeliveryLoopPruneWorker`,
  through `Loopctl.Intake.prune_deliveries/3` — never inside GitHub's redelivery window, and
  never a row an `intake_records.last_delivery_id` still names. See "Retention" in
  `Loopctl.Intake`.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @outcomes ~w(ping recorded ignored)

  schema "intake_deliveries" do
    tenant_field()
    belongs_to :source, Loopctl.Intake.Source
    field :github_delivery_id, :string
    field :event, :string
    field :action, :string
    field :outcome, :string
    field :issue_number, :integer
    field :payload_sha256, :string

    timestamps()
  end

  @doc "The outcomes a delivery row records."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes
end
