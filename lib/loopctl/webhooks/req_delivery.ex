defmodule Loopctl.Webhooks.ReqDelivery do
  @moduledoc """
  Production webhook delivery implementation using Req.

  Makes HTTP POST requests to webhook URLs with JSON payloads.
  Uses a 10-second timeout. Supports Req.Test plug for test mocking.
  """

  @behaviour Loopctl.Webhooks.DeliveryBehaviour

  @impl true
  def deliver(url, body, headers) do
    req_opts =
      [
        url: url,
        method: :post,
        body: body,
        headers: headers,
        receive_timeout: 10_000,
        retry: false
      ]
      |> maybe_add_plug()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status >= 200 and status < 300 ->
        {:ok, %{status: status, body: resp_body_to_string(resp_body)}}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        body_snippet = resp_body |> resp_body_to_string() |> String.slice(0, 200)
        {:error, "HTTP #{status}: #{body_snippet}"}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, "timeout"}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "connection_error: #{inspect(reason)}"}

      {:error, exception} ->
        {:error, "delivery_error: #{inspect(exception)}"}
    end
  end

  defp maybe_add_plug(opts) do
    case Application.get_env(:loopctl, :webhook_req_plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end

  defp resp_body_to_string(body) when is_binary(body), do: body
  defp resp_body_to_string(body) when is_map(body), do: Jason.encode!(body)
  defp resp_body_to_string(body), do: inspect(body)
end
