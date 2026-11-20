defmodule LoopctlE2e.Client do
  @moduledoc """
  The two services a run reads and writes: loopctl and GitHub.

  A client is `{module, conn}`: the module implements this behaviour and `conn` is whatever it
  needs (base URLs and tokens for `LoopctlE2e.Client.Req`, a scripted agent for the test stub).
  It is passed to `LoopctlE2e.Run` as an argument, never read from global state.

  Every call returns `{:ok, status, body}` for any HTTP answer and `{:error, reason}` for a
  transport failure; a stage treats both as one failed poll (US-52.9 failure_modes.partition).
  """

  @type service :: :loopctl | :github
  @type result :: {:ok, non_neg_integer(), term()} | {:error, term()}
  @type t :: {module(), term()}

  @callback get(conn :: term(), service(), path :: String.t(), params :: keyword()) :: result()
  @callback post(conn :: term(), service(), path :: String.t(), body :: map()) :: result()

  @doc "GET `path` on `service` through `client`."
  @spec get(t(), service(), String.t(), keyword()) :: result()
  def get({module, conn}, service, path, params \\ []),
    do: module.get(conn, service, path, params)

  @doc "POST `body` to `path` on `service` through `client`."
  @spec post(t(), service(), String.t(), map()) :: result()
  def post({module, conn}, service, path, body), do: module.post(conn, service, path, body)
end
