defmodule Loopctl.Secrets.Behaviour do
  @moduledoc """
  Behaviour for tenant secret storage (e.g., audit signing private keys).

  Production uses Fly.io secrets via the GraphQL API. Tests use an
  in-memory mock wired through `config/test.exs`.
  """

  @doc "Read a secret by name. Returns the raw bytes."
  @callback get(name :: String.t()) :: {:ok, binary()} | {:error, term()}

  @doc "Write a secret. Overwrites if it already exists."
  @callback set(name :: String.t(), value :: binary()) :: :ok | {:error, term()}

  @doc "Delete a secret by name."
  @callback delete(name :: String.t()) :: :ok | {:error, term()}
end
