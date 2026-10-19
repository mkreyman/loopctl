defmodule Loopctl.Changes.ChgClient do
  @moduledoc """
  loopctl's one outbound call to chg-server: the gap pull,
  `GET /api/v1/changes/:change_id/events?after=N` (US-47.3, Epic 47 PRD §5; mkreyman/chg#33).

  A behaviour resolved through config-based DI (`config :loopctl, :chg_client`), so the
  reconciliation job can be tested without a chg-server and the webhook request path holds no
  reference to it at all. Production is `Loopctl.Changes.ReqChgClient`; the test environment
  is `Loopctl.MockChgClient`.

  ## `events_after/4`

  Signs the request with `secret` (the source's `change_events_secret`) over
  `"<timestamp>.GET.<path>?<query>"` and answers:

  - `{:ok, envelopes}` — the change's events after `after_seq`, in order, as decoded JSON
    objects. Unvalidated: the caller validates each one exactly as it would a push.
  - `{:error, :unauthorized}` — chg-server refused the signature (HTTP 401). Under a
    one-sided secret rotation this is the only signal loopctl gets, so the caller raises an
    operator alert on it.
  - `{:error, reason}` — anything else that is not an answer: unreachable, a timeout, a
    non-200 status, a body that is not a list of events. Transient by assumption; the caller
    retries.
  """

  @callback events_after(
              base_url :: String.t(),
              secret :: binary(),
              change_id :: String.t(),
              after_seq :: non_neg_integer()
            ) :: {:ok, [map()]} | {:error, :unauthorized} | {:error, term()}

  @doc "The configured implementation, resolved at call time."
  @spec impl() :: module()
  def impl, do: Application.get_env(:loopctl, :chg_client, Loopctl.Changes.ReqChgClient)

  @doc """
  The chg-server base URL (`CHG_SERVER_URL`), or `nil` when unset — in which case no pull is
  attempted. One chg-server serves every enrolled repository (chg design §5), so the URL is
  deployment configuration rather than a per-source field.
  """
  @spec base_url() :: String.t() | nil
  def base_url do
    case Application.get_env(:loopctl, :chg_server_url) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end
end
