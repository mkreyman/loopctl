defmodule Loopctl.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Loopctl.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Loopctl.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Loopctl.DataCase
      import Loopctl.Fixtures
      import Mox
    end
  end

  setup tags do
    Loopctl.DataCase.setup_sandbox(tags)
    Mox.set_mox_from_context(tags)
    stub_all_defaults()
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Loopctl.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  Sets permissive default stubs for all Mox mocks.

  These stubs allow tests to run without explicitly setting up
  expectations for every mock. Override with `expect/3` in individual
  tests as needed.
  """
  def stub_all_defaults do
    Mox.stub(Loopctl.MockHealthChecker, :check, fn ->
      {:ok,
       %{
         status: "ok",
         version: "0.1.0-test",
         checks: %{database: "ok", oban: "ok"}
       }}
    end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
