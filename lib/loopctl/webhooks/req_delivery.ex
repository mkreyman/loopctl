defmodule Loopctl.Webhooks.ReqDelivery do
  @moduledoc """
  Production webhook delivery implementation using Req.

  Makes HTTP POST requests to webhook URLs with JSON payloads.
  Uses a 10-second timeout. Supports Req.Test plug for test mocking.
  """

  @behaviour Loopctl.Webhooks.DeliveryBehaviour

  alias Loopctl.Net.UrlGuard

  @impl true
  def deliver(url, body, headers) do
    # Validate AND pin at delivery time (not just at changeset time) to defend
    # against DNS rebinding / TOCTOU (ie-02 / GHSA-jh42-wf7g-f5rg): pin/1 resolves
    # the host ONCE, and pinned_request_opts/1 makes Req connect to that exact IP
    # while keeping the original host for Host/SNI/cert — so there is no second
    # resolution for an attacker to rebind.
    case UrlGuard.pin(url) do
      {:ok, pinned} -> do_deliver(pinned, body, headers)
      {:error, reason} -> {:error, "blocked_url: #{reason}"}
    end
  end

  defp do_deliver(pinned, body, headers) do
    # Fold the caller's headers into pinned_request_opts so the explicit `Host`
    # header it sets is preserved (a plain `Keyword.merge(headers: ...)` would
    # clobber it).
    req_opts =
      UrlGuard.pinned_request_opts(pinned, headers)
      |> Keyword.merge(
        method: :post,
        body: body,
        receive_timeout: 10_000,
        retry: false,
        # Never follow redirects — a 302 hop would re-enter an unvalidated URL,
        # bypassing the egress guard above (ie-02 / GHSA-jh42-wf7g-f5rg).
        redirect: false
      )
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
