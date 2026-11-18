defmodule Loopctl.Changes.LedgerRow do
  @moduledoc """
  Schema for `chg_ledger_rows`: one chg shadow-ledger row a fleet machine delivered
  (US-50.1).

  - `kind` is open. `chg` and `gate` rows carry `sha`, `verdict` and `ms`; other kinds may
    leave them NULL. `raw` is the whole row as delivered.
  - `at` is the row's `at_ms`, as a timestamp.
  - `row_hash` is the sha256 of the row's canonical JSON; with `(tenant_id, source_id, host)`
    it is the idempotency key.
  - `raw` is UNTRUSTED text from a fleet machine: nothing reads it as an instruction.

  Written only by `Loopctl.Changes.Ledger`; there is no changeset because no field is cast from
  a request. `tenant_id` and `source_id` come from the authenticated source.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "chg_ledger_rows" do
    tenant_field()
    field :source_id, :binary_id
    field :repo, :string
    field :host, :string
    field :kind, :string
    field :sha, :string
    field :at, :utc_datetime_usec
    field :verdict, :string
    field :ms, :integer
    field :raw, :map
    field :row_hash, :string

    timestamps(updated_at: false)
  end
end
