defmodule Loopctl.CLI.Client do
  @moduledoc """
  HTTP client for communicating with the loopctl server API.

  Uses Req with support for Req.Test plug-based mocking in tests.
  All requests include the API key as a Bearer token and the
  appropriate Content-Type headers.

  ## DI Configuration

  In `config/test.exs`:

      config :loopctl, :cli_req_plug, {Req.Test, Loopctl.CLI.Client}

  This allows tests to stub HTTP responses via `Req.Test.stub/2`.
  """

  alias Loopctl.CLI.Config

  @doc """
  Makes a GET request to the given API path.

  ## Parameters

  - `path` -- API path (e.g., "/api/v1/tenants/me")
  - `opts` -- keyword list with optional `:params`, `:server`, `:api_key`
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(path, opts \\ []) do
    request(:get, path, opts)
  end

  @doc """
  Makes a POST request to the given API path.

  ## Parameters

  - `path` -- API path
  - `body` -- request body (map, encoded as JSON)
  - `opts` -- keyword list with optional `:server`, `:api_key`
  """
  @spec post(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(path, body, opts \\ []) do
    request(:post, path, Keyword.put(opts, :json, body))
  end

  @doc """
  Makes a PATCH request to the given API path.
  """
  @spec patch(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def patch(path, body, opts \\ []) do
    request(:patch, path, Keyword.put(opts, :json, body))
  end

  @doc """
  Makes a PUT request to the given API path.
  """
  @spec put(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(path, body, opts \\ []) do
    request(:put, path, Keyword.put(opts, :json, body))
  end

  @doc """
  Makes a DELETE request to the given API path.
  """
  @spec delete(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(path, opts \\ []) do
    request(:delete, path, opts)
  end

  # --- Private ---

  defp request(method, path, opts) do
    plug = Application.get_env(:loopctl, :cli_req_plug)
    server = resolve_server(opts, plug)
    api_key = resolve_opt(opts, :api_key, &Config.api_key/0)
    params = Keyword.get(opts, :params)
    json = Keyword.get(opts, :json)
    extra_headers = Keyword.get(opts, :headers, [])

    if is_nil(server) or server == "" do
      {:error, :no_server_configured}
    else
      url = build_url(server, path)

      req_opts =
        [method: method, url: url]
        |> maybe_add_auth(api_key, extra_headers)
        |> maybe_add_json(json)
        |> maybe_add_params(params)
        |> maybe_add_plug(plug)

      case Req.request(req_opts) do
        {:ok, %Req.Response{status: 204}} ->
          {:ok, %{}}

        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_url(server, path) do
    server = String.trim_trailing(server, "/")
    path = if String.starts_with?(path, "/"), do: path, else: "/" <> path
    server <> path
  end

  defp maybe_add_auth(opts, nil, extra_headers) do
    if extra_headers == [] do
      opts
    else
      Keyword.put(opts, :headers, extra_headers)
    end
  end

  defp maybe_add_auth(opts, api_key, extra_headers) do
    headers = [{"authorization", "Bearer #{api_key}"} | extra_headers]
    Keyword.put(opts, :headers, headers)
  end

  defp maybe_add_json(opts, nil), do: opts
  defp maybe_add_json(opts, body), do: Keyword.put(opts, :json, body)

  defp maybe_add_params(opts, nil), do: opts
  defp maybe_add_params(opts, params), do: Keyword.put(opts, :params, params)

  defp maybe_add_plug(opts, nil), do: opts
  defp maybe_add_plug(opts, plug), do: Keyword.put(opts, :plug, plug)

  # When a Req.Test plug is configured, use a canonical localhost URL
  # so the plug receives a valid request path instead of a garbled URL.
  defp resolve_server(opts, plug) do
    case Keyword.fetch(opts, :server) do
      {:ok, nil} when plug != nil -> nil
      {:ok, nil} -> nil
      {:ok, value} -> value
      :error when plug != nil -> "http://localhost:4000"
      :error -> Config.server()
    end
  end

  # If the key is explicitly provided in opts (even as nil), use that value.
  # Otherwise, fall back to the config function.
  defp resolve_opt(opts, key, fallback_fn) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> fallback_fn.()
    end
  end
end
