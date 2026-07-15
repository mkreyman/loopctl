defmodule Loopctl.Provider.RetryAfter do
  @moduledoc """
  Parse a provider `Retry-After` header into a normalized, clamped seconds value
  (US-37.3). RFC 7231 allows two forms:

    * **delta-seconds** — a non-negative integer, e.g. `"30"`.
    * **HTTP-date** (IMF-fixdate) — e.g. `"Wed, 21 Oct 2026 07:28:00 GMT"`; the
      resulting delay is `max(0, seconds_until(date))`.

  The parser is DEFENSIVE: a missing, empty, or malformed header yields `nil`, so
  callers fall back to their existing backoff. The result is CLAMPED to a sane
  maximum (`provider_retry_after_max_seconds`, SystemConfig, default #{300}s) so a
  hostile `Retry-After: 999999999` can never wedge a breaker open or pin an Oban
  queue. NOTE: this parser is provider-GENERIC (it serves BOTH the embedding client
  AND the Anthropic client), so its clamp ceiling is a provider-neutral key —
  distinct from the embedding-breaker-specific `embedding_breaker_max_cooldown_seconds`
  that governs how long the embedding circuit breaker stays open.

  Both provider clients (`Loopctl.Knowledge.EmbeddingClient`,
  `Loopctl.Llm.Anthropic`) call `from_response/2` on a throttle response
  (`429`/`503`) to attach the parsed seconds to the sanitized error term; the
  breaker cooldown and the Oban worker snooze read it back via `from_error/1`.
  """

  alias Loopctl.SystemConfig

  # Statuses that carry a meaningful Retry-After (throttle / temporarily
  # unavailable). Other statuses' Retry-After (if any) is ignored.
  @throttle_statuses [429, 503]

  # Clamp ceiling for a parsed Retry-After (seconds). Live-tunable; the in-code
  # default doubles as the documented default.
  @default_max_seconds 300

  @doc """
  Parse a raw `Retry-After` header value into non-negative clamped seconds, or
  `nil` when absent/malformed.
  """
  @spec parse(String.t() | nil) :: non_neg_integer() | nil
  def parse(nil), do: nil

  def parse(value) when is_binary(value) do
    case parse_value(String.trim(value)) do
      nil -> nil
      seconds -> clamp(seconds)
    end
  end

  def parse(_other), do: nil

  @doc """
  Extract the parsed Retry-After from a throttle response, but ONLY for a
  throttle status (`429`/`503`). Returns `nil` otherwise. `resp` is a
  `%Req.Response{}`; its `retry-after` header is a list of values (lowercased by
  Req) — the first is used.
  """
  @spec from_response(integer(), Req.Response.t()) :: non_neg_integer() | nil
  def from_response(status, %Req.Response{} = resp) when status in @throttle_statuses do
    resp
    |> Req.Response.get_header("retry-after")
    |> List.first()
    |> parse()
  end

  def from_response(_status, _resp), do: nil

  @doc """
  Read a parsed Retry-After back out of a sanitized throttle error term (the
  4-tuple `{:api_error, status, :provider_error, retry_after}`). Any other term
  yields `nil`.
  """
  @spec from_error(term()) :: non_neg_integer() | nil
  def from_error({:api_error, _status, _tag, retry_after})
      when is_integer(retry_after) and retry_after >= 0,
      do: retry_after

  def from_error(_other), do: nil

  @doc """
  Normalize a parsed Retry-After into a POSITIVE Oban snooze interval (seconds).

  A provider may legitimately send `Retry-After: 0` (parsed to `0`), and RFC 7231
  permits it. But `{:snooze, 0}` reschedules effectively immediately AND bumps
  `max_attempts`, so on a breaker-LESS path (the Anthropic content-ingestion
  worker) a provider persistently returning `429/503` + `Retry-After: 0` would
  hot-loop with no attempt cap — the exact behavior AC-37.3.5 says to avoid.
  Floor at `1` so every throttle snooze makes forward progress. (US-37.3 review.)
  """
  @spec snooze_seconds(non_neg_integer()) :: pos_integer()
  def snooze_seconds(retry_after) when is_integer(retry_after), do: max(retry_after, 1)

  @doc """
  The clamp ceiling (seconds) for a parsed Retry-After. Live-tunable via the
  provider-neutral `"provider_retry_after_max_seconds"` SystemConfig key.

  This parser is shared by every provider client, so its ceiling is deliberately
  NOT the embedding-breaker key: an operator tuning the embedding breaker's open
  cooldown (`embedding_breaker_max_cooldown_seconds`) must not silently move the
  Anthropic ingestion snooze ceiling too.
  """
  @spec max_seconds() :: pos_integer()
  def max_seconds do
    SystemConfig.get_int("provider_retry_after_max_seconds", @default_max_seconds)
  end

  defp clamp(seconds), do: seconds |> max(0) |> min(max_seconds())

  defp parse_value(""), do: nil

  defp parse_value(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> n
      # Not a bare non-negative integer — try the HTTP-date form. A negative or
      # fractional value (e.g. "-5", "30.5") is malformed per RFC → nil.
      _ -> parse_http_date(str)
    end
  end

  # IMF-fixdate parsing with Erlang stdlib (no new dep, no manual date math):
  # `:httpd_util.convert_request_date/1` returns a UTC erlang datetime or
  # `:bad_date`. It also RAISES (FunctionClauseError) on some non-date charlists
  # (e.g. `~c"-5"`), so rescue defensively — any parse failure is `nil`.
  defp parse_http_date(str) do
    case :httpd_util.convert_request_date(String.to_charlist(str)) do
      {{_y, _mo, _d}, {_h, _mi, _s}} = erl_datetime ->
        case DateTime.from_naive(NaiveDateTime.from_erl!(erl_datetime), "Etc/UTC") do
          {:ok, dt} -> max(0, DateTime.diff(dt, DateTime.utc_now()))
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
