defmodule Loopctl.WebAuthn.RpConfig do
  @moduledoc """
  #511 — resolves the WebAuthn relying-party overrides (`WEBAUTHN_RP_ID`,
  `WEBAUTHN_ORIGIN`, `WEBAUTHN_RP_NAME`) from raw operator env values.

  Extracted from the prod block of `config/runtime.exs` — which no test can reach — so
  the blank/shape/default rules are unit-testable, the `Loopctl.Search.Regconfig`
  precedent for an operator knob whose bad values must degrade rather than crash boot.

  Pure by design: it reads no config and logs nothing, returning warnings for the caller
  to print, because `Logger` is not started when a release's config provider evaluates
  `runtime.exs`.

  ## Rules

    * A blank value is unset — an empty string is truthy in Elixir, and the naive
      `if System.get_env(...)` set `rp_id: ""`, breaking every ceremony while the
      release booted clean.
    * `rp_id` must be a bare host (no scheme, port, path or whitespace) with at least
      one alphanumeric label; `origin` must be `scheme://host[:port]` with no trailing
      slash or path, because Wax compares it to `clientDataJSON.origin` by exact string.
      A non-conforming value is DROPPED WITH A WARNING, leaving the `config.exs` default
      in place — a bad value must never crash boot (epic_35 STH_SWEEP_CRON lesson), but
      not-crashing and not-telling-anyone are separable.
    * `origin` defaults to `https://$PHX_HOST` — the page host, NOT `https://<rp_id>`:
      `rp_id` need only be a registrable SUFFIX of the origin, so a parent-domain
      `rp_id` (`example.com` while serving `app.example.com`) is legal and deriving the
      origin from it makes Wax reject an attestation the browser was happy to produce.
      An UNSET `PHX_HOST` derives nothing: its `example.com` placeholder is a value the
      operator never supplied. There is no `http://` default — WebAuthn runs only in a
      secure context (localhost excepted), so localhost or a non-standard port must set
      `WEBAUTHN_ORIGIN` explicitly.
    * A configured `rp_id` that is not a registrable suffix of the configured origin is
      warned about, as is an origin set WITHOUT an `rp_id` (the compiled default
      `loopctl.com` is a suffix of almost no self-hosted origin).
  """

  @rp_id ~r/^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$/
  @origin ~r{^https?://[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(:\d+)?$}

  @doc """
  Resolves raw `:rp_id`, `:rp_name`, `:origin` and `:phx_host` env values (each a string
  or `nil`) into `{webauthn_opts, warnings}`.

  `webauthn_opts` carries only the keys that were resolved, so it can be deep-merged onto
  the `config.exs` block; `[]` means "leave the compiled config untouched".
  """
  @spec resolve(keyword()) :: {keyword(), [String.t()]}
  def resolve(env) do
    {rp_id, rp_id_warnings} =
      validated(env[:rp_id], "WEBAUTHN_RP_ID", @rp_id, "a bare host (no scheme, port or path)")

    {configured_origin, origin_warnings} =
      validated(env[:origin], "WEBAUTHN_ORIGIN", @origin, "scheme://host[:port] with no path")

    origin = configured_origin || derived_origin(presence(env[:phx_host]))

    opts =
      [rp_id: rp_id, rp_name: presence(env[:rp_name]), origin: origin]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    {opts,
     rp_id_warnings ++ origin_warnings ++ pairing_warnings(rp_id, origin, configured_origin)}
  end

  defp validated(raw, name, shape_regex, shape) do
    case presence(raw) do
      nil ->
        {nil, []}

      value ->
        if Regex.match?(shape_regex, value) do
          {value, []}
        else
          {nil,
           [
             "#{name}=#{inspect(value)} is not #{shape}; ignoring it and keeping the " <>
               "compiled default, which will fail the enrollment ceremony in the browser."
           ]}
        end
    end
  end

  defp presence(nil), do: nil

  defp presence(raw) do
    case String.trim(raw) do
      "" -> nil
      value -> value
    end
  end

  defp derived_origin(nil), do: nil

  defp derived_origin(host) do
    candidate = "https://#{host}"
    if Regex.match?(@origin, candidate), do: candidate
  end

  defp pairing_warnings(nil, _origin, nil), do: []

  defp pairing_warnings(nil, _origin, configured_origin) do
    [
      "WEBAUTHN_ORIGIN=#{configured_origin} is set while WEBAUTHN_RP_ID is not, so the " <>
        "compiled default rp_id applies; the browser refuses the ceremony unless it is a " <>
        "registrable suffix of that origin."
    ]
  end

  defp pairing_warnings(_rp_id, nil, _configured), do: []

  defp pairing_warnings(rp_id, origin, _configured) do
    host = origin |> String.replace(~r{^https?://}, "") |> String.split(":") |> hd()

    if host == rp_id or String.ends_with?(host, "." <> rp_id) do
      []
    else
      [
        "WEBAUTHN_RP_ID=#{rp_id} is not a registrable suffix of the WebAuthn origin " <>
          "#{origin}; the browser will refuse every enrollment ceremony."
      ]
    end
  end
end
