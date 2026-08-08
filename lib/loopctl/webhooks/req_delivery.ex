defmodule Loopctl.Webhooks.ReqDelivery do
  @moduledoc """
  Production webhook delivery implementation using Req.

  Makes HTTP POST requests to webhook URLs with JSON payloads.
  Uses a 10-second timeout. Supports Req.Test plug for test mocking.

  ## The egress decision is delegated, never re-derived (US-41.5, AC-41.5.1)

  A webhook destination is a TENANT-SUPPLIED url carrying TENANT CONTENT, so it
  consults the ONE egress policy (`Loopctl.Egress.Policy.check/4`) with purpose
  `:webhook` and `tenant_supplied: true` — exactly as the ingestion fetch and the
  tenant-configured chat endpoint do. That single call subsumes what this module
  used to do with a bare `UrlGuard.pin/1`, and adds the locality decision on top:

    * the SSRF denylist stays MANDATORY for every scope, marked or not
      (`tenant_supplied: true` makes a `:denylisted` verdict the PERMANENT
      `:egress_blocked` on the default path) — GHSA-jh42-wf7g-f5rg stays closed;
    * on a `local_only` scope a destination that is not `:network_local`
      (operator deployment allowlist) or `:tenant_declared` FOR THE `webhook`
      PURPOSE is refused BEFORE the request is built;
    * conversely, an allowlisted or purpose-declared destination now BECOMES
      deliverable — the old unconditional `UrlGuard.pin/1` refused every
      loopback/private destination for every tenant.

  The pin is still applied (`pinned_request_opts/2` + `redirect: false`), so the
  IP connected to is the IP that was classified: no second resolution for an
  attacker to rebind (ie-02 / GHSA-jh42-wf7g-f5rg).

  `scope: nil` is OPERATOR-PLANE delivery (scale alerts). No tenant marking
  applies, so it keeps the SSRF denylist alone — the same `UrlGuard` primitive
  the policy composes, not a second policy. See `docs/egress-guard.md`.
  """

  @behaviour Loopctl.Webhooks.DeliveryBehaviour

  alias Loopctl.Egress.Policy
  alias Loopctl.Egress.Scope
  alias Loopctl.Net.UrlGuard

  @impl true
  def deliver(url, body, headers, scope)

  def deliver(url, body, headers, %Scope{} = scope) do
    # `tenant_supplied: true`: the destination is tenant-writable, so the default
    # (non-local_only) path must NOT degrade to an unpinned, redirect-following
    # request when classification fails — it fails CLOSED as the TRANSIENT
    # `:egress_unavailable`, and a denylisted host is the PERMANENT
    # `:egress_blocked`. That is the same semantic the old `UrlGuard.pin/1`
    # refusal had, expressed through the ONE policy.
    case Policy.check(scope, url, :webhook, tenant_supplied: true) do
      {:ok, %{} = pinned} ->
        do_deliver(pinned, body, headers)

      # Unreachable for `tenant_supplied: true` (that path refuses instead of
      # degrading), but the policy's contract still admits it — so handle it as a
      # REFUSAL rather than letting a future policy change silently hand webhook
      # delivery an unpinned, redirect-following request to a tenant-chosen host.
      {:ok, :unpinned} ->
        {:refused, {:egress_unavailable, unpinnable_details(scope, url)}}

      {:error, tag, details} ->
        {:refused, {tag, details}}
    end
  end

  def deliver(url, body, headers, nil) do
    case UrlGuard.pin(url) do
      {:ok, pinned} -> do_deliver(pinned, body, headers)
      {:error, reason} -> {:error, "blocked_url: #{reason}"}
    end
  end

  defp unpinnable_details(scope, url) do
    %{
      host: URI.parse(url).host,
      scope: Scope.key(scope),
      verdict: :unclassifiable,
      remediation:
        "The webhook destination could not be pinned, so nothing was sent. This is " <>
          "TRANSIENT — the delivery is retried. Verify the destination host resolves " <>
          "from loopctl and re-check with the egress_posture tool."
    }
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

      {:ok, %Req.Response{status: status} = resp} ->
        {:error, "HTTP #{status}#{failure_metadata(resp)}"}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, "timeout"}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "connection_error: #{inspect(reason)}"}

      {:error, exception} ->
        {:error, "delivery_error: #{inspect(exception)}"}
    end
  end

  # What a FAILED delivery is allowed to say about the response.
  #
  # The error string built here is persisted on the delivery event and read back
  # by the tenant through the deliveries API, so it must describe the FAILURE
  # without reproducing what the destination SENT. A destination is
  # tenant-supplied, so echoing its body would make the delivery record a
  # general-purpose reader for whatever loopctl can reach — the response content
  # would flow back out through an API the destination's owner does not control.
  #
  # Status code and `content-type` are the two facts a tenant debugging their own
  # receiver actually needs ("it 500s", "it answered HTML, not JSON"), and neither
  # carries response content. Everything else stays inside loopctl.
  #
  # The header VALUE is still chosen by the destination, so it is TRUNCATED: the
  # error string is persisted on the delivery event and read back through the
  # deliveries API, and an unbounded copy would let a hostile receiver inflate
  # that column at will — reopening, by the byte, the channel this function
  # closes. No real media type comes near the bound.
  @max_content_type_chars 96

  defp failure_metadata(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "content-type") do
      [content_type | _] when is_binary(content_type) ->
        type =
          content_type
          |> String.split(";")
          |> hd()
          |> String.trim()
          |> String.slice(0, @max_content_type_chars)

        " (content-type: #{type})"

      _ ->
        ""
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
