defmodule Loopctl.Security.SecretDenylist do
  @moduledoc """
  Shared secret-pattern denylist.

  Mirrors, in Elixir, the exact regex set the knowledge-capture summarizer uses
  in `claude-config/hooks/knowledge-capture.sh` (the "knowledge extractor"): a
  hit means the scanned text almost certainly carries a credential and must NOT
  be persisted. Used by the coordination bus (`Loopctl.Coordination.ChannelPost`)
  to scan `body`, every `refs` value, and `key` before a post lands — a match is
  an explicit rejection (surfaced as a 422), never a silent drop.

  The set is deliberately the same across the fleet so an operator reasons about
  one denylist, not two. It targets high-confidence credential shapes (long,
  prefixed tokens / key material), not general "looks secret-ish" heuristics, to
  keep false positives near zero on ordinary coordination chatter.
  """

  # High-confidence credential patterns. Kept in lock-step with
  # claude-config/hooks/knowledge-capture.sh (the bash `jq | test(...)` set).
  @patterns [
    # Bearer <token>
    ~r/Bearer\s+[A-Za-z0-9_\-]{20,}/i,
    # OpenAI / Anthropic style sk- keys
    ~r/\bsk-[A-Za-z0-9_\-]{20,}/i,
    # loopctl agent/orchestrator keys
    ~r/\blc_[A-Za-z0-9_\-]{20,}/,
    # GitHub personal-access / OAuth / server / refresh tokens
    ~r/\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}/i,
    # AWS access key id
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    # PEM private key blocks
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    # Slack tokens (bot/user/app/refresh/legacy)
    ~r/\bxox[baprs]-[A-Za-z0-9\-]{10,}/i
  ]

  @doc """
  Returns `true` when `value` matches any denylisted secret pattern.

  Non-binary input (including `nil`) is treated as "no secret" so callers can
  scan optional fields without pre-filtering.
  """
  @spec contains_secret?(term()) :: boolean()
  def contains_secret?(value) when is_binary(value) do
    Enum.any?(@patterns, &Regex.match?(&1, value))
  end

  def contains_secret?(_), do: false

  @doc """
  Returns `true` when ANY string in `values` matches a denylisted pattern.

  Non-binary members are ignored. Useful for scanning a heterogeneous set such
  as `[body, key | Map.values(refs)]` in one call.
  """
  @spec any_contains_secret?(Enumerable.t()) :: boolean()
  def any_contains_secret?(values) do
    Enum.any?(values, &contains_secret?/1)
  end
end
