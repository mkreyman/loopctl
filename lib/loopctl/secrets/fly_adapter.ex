defmodule Loopctl.Secrets.FlyAdapter do
  @moduledoc """
  Fly.io secret storage via the GraphQL API.

  Uses the `setSecrets` and `unsetSecrets` mutations against
  `https://api.fly.io/graphql`. Authenticates via the `FLY_API_TOKEN`
  env variable.

  Secret reads use `fly secrets list` semantics — the Fly API does not
  expose secret values via GraphQL. Instead, the secret is read from the
  application's runtime environment (`System.get_env/1`). This means
  a deploy is required after `setSecrets` for the new value to be
  available in the running application.

  For tenant audit keys, the ETS cache in `Loopctl.TenantKeys` handles
  the gap: on first read after a deploy the key is pulled from env and
  cached for 5 minutes.
  """

  @behaviour Loopctl.Secrets.Behaviour

  require Logger

  @graphql_url "https://api.fly.io/graphql"

  @impl true
  def get(name) when is_binary(name) do
    case System.get_env(name) do
      nil -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  @impl true
  def set(name, value) when is_binary(name) and is_binary(value) do
    app_name = fly_app_name()
    token = fly_api_token()

    if is_nil(app_name) or is_nil(token) do
      Logger.error("FlyAdapter: FLY_APP_NAME or FLY_API_TOKEN not configured")
      {:error, :fly_not_configured}
    else
      body =
        Jason.encode!(%{
          query: """
          mutation($input: SetSecretsInput!) {
            setSecrets(input: $input) {
              release { id version }
            }
          }
          """,
          variables: %{
            input: %{
              appId: app_name,
              secrets: [%{key: name, value: Base.encode64(value)}]
            }
          }
        })

      case Req.post(@graphql_url,
             body: body,
             headers: [
               {"authorization", "Bearer #{token}"},
               {"content-type", "application/json"}
             ],
             connect_options: [timeout: 10_000],
             receive_timeout: 15_000
           ) do
        {:ok, %{status: 200, body: %{"data" => %{"setSecrets" => _}}}} ->
          :ok

        {:ok, %{status: 200, body: %{"errors" => errors}}} ->
          Logger.error("FlyAdapter setSecrets error: #{inspect(errors)}")
          {:error, {:fly_api_error, errors}}

        {:ok, %{status: status}} ->
          Logger.error("FlyAdapter setSecrets HTTP #{status}")
          {:error, {:http_error, status}}

        {:error, reason} ->
          Logger.error("FlyAdapter setSecrets failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @impl true
  def delete(name) when is_binary(name) do
    app_name = fly_app_name()
    token = fly_api_token()

    if is_nil(app_name) or is_nil(token) do
      {:error, :fly_not_configured}
    else
      body =
        Jason.encode!(%{
          query: """
          mutation($input: UnsetSecretsInput!) {
            unsetSecrets(input: $input) {
              release { id version }
            }
          }
          """,
          variables: %{
            input: %{
              appId: app_name,
              keys: [name]
            }
          }
        })

      case Req.post(@graphql_url,
             body: body,
             headers: [
               {"authorization", "Bearer #{token}"},
               {"content-type", "application/json"}
             ],
             connect_options: [timeout: 10_000],
             receive_timeout: 15_000
           ) do
        {:ok, %{status: 200}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fly_app_name, do: System.get_env("FLY_APP_NAME")
  defp fly_api_token, do: System.get_env("FLY_API_TOKEN")
end
