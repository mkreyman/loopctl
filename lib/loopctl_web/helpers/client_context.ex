defmodule LoopctlWeb.Helpers.ClientContext do
  @moduledoc """
  Decodes the client-asserted search context header (#658).

  UNTRUSTED BY CONSTRUCTION and analytics-only: none of it is derivable server-side (an
  api_key names a KEY, and under the v2 dispatch pattern a key is minted per dispatch, so
  the server cannot tell which agent searched, at what effort, or from which repo). It must
  never gate access — the api key remains the sole authority — which is why every field is
  stored under a `client_` prefix. Malformed input yields an empty map, never an error: a
  broken header must not fail a search.

  Lives here rather than in one controller because every writer into `search_events` needs
  the same decode; a second copy would drift and leave one endpoint's rows all-NULL.
  """

  # Base64-encoded JSON so an arbitrary repo name or hostname cannot break header parsing.
  @header "x-loopctl-client-context"
  @max_field_bytes 200
  @fields Map.new(
            ~w(session_id effort model host repo entrypoint kind version),
            &{&1, :"client_#{&1}"}
          )

  @doc "The `client_*` attrs asserted by this request, or `%{}` when absent/malformed."
  def attrs(conn) do
    with [raw] <- Plug.Conn.get_req_header(conn, @header),
         {:ok, json} <- Base.decode64(raw, padding: false),
         {:ok, %{} = map} <- JSON.decode(json) do
      fields(map)
    else
      _ -> %{}
    end
  end

  @doc "The request header name, for docs and tests."
  def header, do: @header

  # Only the declared keys, only binaries, each length-bounded — the payload is
  # attacker-shaped by definition and lands in an operator's analysis table.
  defp fields(map) do
    Enum.reduce(@fields, %{}, fn {key, field}, acc ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> Map.put(acc, field, truncate(value))
        _ -> acc
      end
    end)
  end

  # BYTES, not graphemes: the columns are varchar(255) and `String.slice/3` counts
  # graphemes, so 200 multibyte graphemes overflowed the column, Postgres raised, and the
  # recorder's rescue dropped the ENTIRE row — one header blanking a client's own analytics.
  defp truncate(value) when byte_size(value) <= @max_field_bytes, do: value
  defp truncate(value), do: value |> binary_part(0, @max_field_bytes) |> trim_valid()

  defp trim_valid(""), do: ""

  defp trim_valid(bin),
    do: if(String.valid?(bin), do: bin, else: trim_valid(binary_part(bin, 0, byte_size(bin) - 1)))
end
