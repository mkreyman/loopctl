defmodule Loopctl.Changes.Finding do
  @moduledoc """
  Schema for `chg_findings` (US-51.1): one problem the nightly sweep derived from the chg
  ledger, keyed by `(tenant_id, kind, fingerprint)`.

  ## The states

  - `:queued` — derived, not yet filed: over the day's cap, or waiting for an intake source on
    the owning repository.
  - `:filed` — an `open` action is decided; `issue_number` is set once it ran.
  - `:fixed` — the story the delivery loop made from the issue merged (US-51.2).
  - `:closed` — the signal stayed quiet for the quiet period after the fix (US-51.2).
  - `:escalated` — a person must look: depth 2, or two fixes that did not hold.
    `escalated_reason` says which.

  Every field is set by `Loopctl.Changes.Findings`; nothing is cast from a request.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @states [:queued, :filed, :fixed, :closed, :escalated]
  @kinds ~w(selection_miss flaky_test missing_review stuck_change source_silent)

  schema "chg_findings" do
    tenant_field()

    field :kind, :string
    field :fingerprint, :string
    field :repo_full_name, :string
    field :evidence, :map, default: %{}

    field :state, Ecto.Enum, values: @states, default: :queued
    field :occurrences, :integer, default: 1
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    field :loop_depth, :integer, default: 0
    field :fix_attempts, :integer, default: 0
    # How many times a person cleared it from escalated (US-51.6); part of every action key.
    field :cycle, :integer, default: 0

    field :issue_number, :integer
    field :filed_at, :utc_datetime_usec
    field :fix_merge_sha, :string
    field :fixed_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :escalated_at, :utc_datetime_usec
    field :escalated_reason, :string

    timestamps()
  end

  @doc "The finding states."
  @spec states() :: [atom()]
  def states, do: @states

  @doc "The finding kinds the sweep derives."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds
end
