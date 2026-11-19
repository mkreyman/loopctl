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

  @doc """
  The failing `gate` rows that are a gate's verdict on the TESTS: the rows a selection miss
  pairs with a passing selecting `chg` row (`Loopctl.Changes.Findings`, and
  `Loopctl.Changes.Dashboard`'s miss list).

  A row with `source: "hook"` is left out. It is the pre-push hook's final decision on a push
  (`chg shadow record --source hook`), and it fails a push chg passed for reasons outside the
  selection: a walk lane, a moved tree. chg's own report never pairs it (`cli/src/shadow.rs`
  `report/2`), #1061. A NULL source is an older local row and stays in.
  """
  @spec failing_test_gates(Ecto.UUID.t()) :: Ecto.Query.t()
  def failing_test_gates(tenant_id) do
    import Ecto.Query

    from g in __MODULE__,
      where:
        g.tenant_id == ^tenant_id and g.kind == "gate" and g.verdict == "fail" and
          fragment("coalesce(?->>'source', '') <> 'hook'", g.raw)
  end
end
