defmodule LoopctlE2e.Client.Witness do
  @moduledoc """
  loopctl's witness protocol (chain of custody v2, section 4.4) for the live client: every
  authenticated request echoes the caller's last-known Signed Tree Head in
  `x-loopctl-last-known-sth`, and a caller that has none asks for it with
  `x-loopctl-sth-bootstrap: true`. Without either, loopctl answers `412 witness_header_missing`
  before the request runs.

  The bootstrap grace is one-time per API key, and every e2e run starts a new process with the
  same orchestrator key. So from the second run on, the first request gets
  `412 witness_bootstrap_already_consumed`, which carries the current STH in
  `x-loopctl-current-sth`. The client caches it and retries that request once. This is safe,
  because the witness plug stops the request before it does anything. Every response that
  carries the header refreshes the cache. This is the same contract as
  `mcp-server/lib/witness-sth.js`.
  """

  @sth_shape ~r/\A\d+:[A-Za-z0-9_-]{22}\z/
  @retry_code "witness_bootstrap_already_consumed"

  @doc "The witness header for a request, given the cached STH (nil before the first one)."
  @spec headers(String.t() | nil) :: [{String.t(), String.t()}]
  def headers(nil), do: [{"x-loopctl-sth-bootstrap", "true"}]
  def headers(sth), do: [{"x-loopctl-last-known-sth", sth}]

  @doc """
  The STH a response hands back, or nil. Req lowercases header names and gives each value as a
  list.
  """
  @spec current_sth(map()) :: String.t() | nil
  def current_sth(resp_headers) do
    case Map.get(resp_headers, "x-loopctl-current-sth") do
      [sth | _] -> if Regex.match?(@sth_shape, sth), do: sth
      _ -> nil
    end
  end

  @doc """
  True for the one refusal that is retried: a spent bootstrap grace that came with an STH.
  A `409 witness_divergence` is not retried; its STH is cached, so the next request uses it.
  """
  @spec retry?(non_neg_integer(), term(), String.t() | nil) :: boolean()
  def retry?(412, %{"error" => %{"code" => @retry_code}}, sth) when is_binary(sth), do: true
  def retry?(_status, _body, _sth), do: false
end
