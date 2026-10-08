defmodule Loopctl.Test.BrokenChain do
  @moduledoc """
  Makes one tenant's audit chain refuse every append, for tests of how a write the chain
  refuses is answered.

  The chain cannot be driven to that state through the application, since every append reads
  the head it links to under the chain lock. So a trigger raising what the chain raises (P0001
  `audit_chain_hash_violation` by default) is installed on `audit_chain` for that tenant only
  (`WHEN` on `tenant_id`), COMMITTED, and dropped when the test exits. Committed DDL on a table
  every test appends to is why only an `async: false` module may call it.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo

  @default_text "audit_chain_hash_violation: injected by test"

  @doc """
  Installs the refusing trigger for `tenant_id`, raising `text`, and drops it on test exit.
  """
  @spec install!(String.t(), String.t()) :: :ok
  def install!(tenant_id, text \\ @default_text) do
    {:ok, _} = Ecto.UUID.cast(tenant_id)
    name = trigger_name(tenant_id)
    # Registered first, so a CREATE TRIGGER that fails after its function committed still
    # drops the function. `remove!/1` is IF EXISTS throughout.
    on_exit(fn -> remove!(tenant_id) end)

    unboxed(fn ->
      AdminRepo.query!("""
      CREATE OR REPLACE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '%', #{quote_literal(text)} USING ERRCODE = 'P0001';
      END
      $$
      """)

      AdminRepo.query!("DROP TRIGGER IF EXISTS #{name} ON audit_chain")

      AdminRepo.query!("""
      CREATE TRIGGER #{name} BEFORE INSERT ON audit_chain FOR EACH ROW
      WHEN (NEW.tenant_id = '#{tenant_id}') EXECUTE FUNCTION #{name}()
      """)
    end)

    :ok
  end

  # A SQL string literal; `text` is test-supplied, and a quote in it must not end the literal.
  defp quote_literal(text), do: "'" <> String.replace(text, "'", "''") <> "'"

  @doc "Drops `tenant_id`'s refusing trigger, if it is installed."
  @spec remove!(String.t()) :: :ok
  def remove!(tenant_id) do
    name = trigger_name(tenant_id)

    unboxed(fn ->
      AdminRepo.query!("DROP TRIGGER IF EXISTS #{name} ON audit_chain")
      AdminRepo.query!("DROP FUNCTION IF EXISTS #{name}()")
    end)

    :ok
  end

  defp trigger_name(tenant_id), do: "test_broken_chain_" <> String.replace(tenant_id, "-", "")

  defp unboxed(fun), do: Sandbox.unboxed_run(Loopctl.Repo, fun)
end
