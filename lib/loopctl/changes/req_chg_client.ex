defmodule Loopctl.Changes.ReqChgClient do
  @moduledoc """
  The production `Loopctl.Changes.ChgClient`: the signed gap pull over `Req`.

  Bounded like every other outbound read here: a 2s connect and a 5s receive timeout,
  `retry: false` (the Oban job is the retry, with its own backoff) and `redirect: false`, so a
  misconfigured URL cannot silently hand the signed request to another host. The signature is
  computed over the path and query EXACTLY as sent — the query is built here and carries only
  `after`, as the contract requires.
  """

  @behaviour Loopctl.Changes.ChgClient

  alias Loopctl.Changes.Signature

  @connect_timeout_ms 2_000
  @receive_timeout_ms 5_000

  @impl true
  def events_after(base_url, secret, change_id, after_seq)
      when is_binary(base_url) and is_binary(change_id) and is_integer(after_seq) do
    path = "/api/v1/changes/#{URI.encode(change_id, &URI.char_unreserved?/1)}/events"
    query = "after=#{after_seq}"
    timestamp = Integer.to_string(System.os_time(:second))
    signature = Signature.header(secret, Signature.pull_string(timestamp, path, query))

    url = String.trim_trailing(base_url, "/") <> path <> "?" <> query

    url
    |> Req.get(request_options(timestamp, signature))
    |> answer()
  end

  defp request_options(timestamp, signature) do
    maybe_add_plug(
      headers: [
        {"x-chg-timestamp", timestamp},
        {"x-chg-signature", signature},
        {"accept", "application/json"}
      ],
      retry: false,
      redirect: false,
      receive_timeout: @receive_timeout_ms,
      connect_options: [timeout: @connect_timeout_ms]
    )
  end

  defp answer({:ok, %Req.Response{status: 200, body: body}}), do: events(body)
  defp answer({:ok, %Req.Response{status: 401}}), do: {:error, :unauthorized}
  defp answer({:ok, %Req.Response{status: 404}}), do: {:error, :unknown_change}
  defp answer({:ok, %Req.Response{status: status}}), do: {:error, {:chg_server_error, status}}

  # The exception's module only (`Req.TransportError`, ...): never its message, which can
  # carry the URL.
  defp answer({:error, %{__struct__: module}}),
    do: {:error, {:chg_server_unreachable, module}}

  # mkreyman/chg#33 item 6: a 200 is always `{"events": [...], "next_after": N | null}`, at
  # most 500 events in seq order. `next_after` is not read: the caller pages from the seq it
  # applied, and an empty page ends the pull.
  defp events(%{"events" => list}) when is_list(list), do: {:ok, list}
  defp events(_body), do: {:error, :invalid_response}

  # The same `Req.Test` seam the forge clients use (`:delivery_github_req_plug`), so the
  # signing and the response mapping are exercised against real requests in test.
  defp maybe_add_plug(opts) do
    case Application.get_env(:loopctl, :chg_req_plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end
end
