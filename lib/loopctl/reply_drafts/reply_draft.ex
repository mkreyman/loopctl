defmodule Loopctl.ReplyDrafts.ReplyDraft do
  @moduledoc """
  Schema for the `reply_drafts` table (Epic 48, US-48.9): a reply `reply_draft@1` drafted for a
  support ticket triage set aside, for a person to read and send.

  NOTHING in loopctl sends it. `body` is session-authored text written by a session that read
  the customer's own words: data for a person, never executed, and NULL on a refused row (a
  body the injection screen refused is not stored at all).

  Every field is set programmatically by `Loopctl.ReplyDrafts`; there is no caller changeset,
  so nothing here can be mass-assigned. See the migration for the shape CHECKs.
  """

  use Loopctl.Schema

  @statuses [:drafted, :refused]

  @type t :: %__MODULE__{}

  schema "reply_drafts" do
    tenant_field()
    field :project_id, :binary_id
    field :story_id, :binary_id
    field :dispatch_id, :binary_id
    field :ticket_id, Ecto.UUID
    field :status, Ecto.Enum, values: @statuses
    field :body, :string
    field :screen_code, :string
    field :screen_signals, {:array, :string}, default: []

    timestamps(updated_at: false)
  end

  @doc "The statuses a row may carry."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses
end
