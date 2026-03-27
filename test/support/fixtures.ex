defmodule Loopctl.Fixtures do
  @moduledoc """
  Test fixture helpers for building and inserting test data.

  - `build/2` — returns a map or struct without touching the database.
  - `fixture/2` — inserts into the database, auto-creating dependencies.

  All fixtures use binary UUIDs. Tenant isolation tests should create
  separate tenants via `fixture(:tenant)`.
  """

  alias Loopctl.Tenants.Tenant

  @doc """
  Builds a data map for the given type without database insertion.
  Useful for changeset tests and unit tests that don't need persistence.
  """
  def build(:tenant, attrs \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        name: "Test Tenant #{System.unique_integer([:positive])}",
        slug: "test-tenant-#{System.unique_integer([:positive])}",
        status: "active"
      },
      Enum.into(attrs, %{})
    )
  end

  @doc """
  Inserts a record into the database, auto-creating any required dependencies.
  Returns the inserted struct.
  """
  def fixture(type, attrs \\ %{})

  def fixture(:tenant, attrs) do
    data = build(:tenant, attrs)

    %Tenant{}
    |> Ecto.Changeset.cast(data, [:id, :name, :slug, :status])
    |> Ecto.Changeset.validate_required([:name, :slug, :status])
    |> Loopctl.Repo.insert!()
  end

  @doc """
  Generates a fresh binary UUID for use in tests.
  """
  def uuid, do: Ecto.UUID.generate()
end
