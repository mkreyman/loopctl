defmodule Loopctl.Security.SecretDenylist do
  @moduledoc """
  Shared secret-pattern denylist.

  The canonical credential-shape set lives in the bash knowledge-capture
  summarizer at `claude-config/hooks/knowledge-capture.sh` (the "knowledge
  extractor"); this module re-implements those credential patterns in Elixir so
  the same shapes are blocked on the coordination plane. A hit means the scanned
  text almost certainly carries a credential and must NOT be persisted. Used by
  the coordination bus (`Loopctl.Coordination.ChannelPost`) to scan `body`,
  `key`, `session_id`, `host`, and every `refs` value before a post lands — a
  match is an explicit rejection (surfaced as a 422), never a silent drop.

  ## Best-effort, NOT a DLP boundary

  This targets ~11 high-confidence, *prefixed* credential shapes (see `@patterns`)
  to keep false positives near zero on ordinary chatter. It is deliberately NOT a
  comprehensive credential filter and MUST NOT be relied on as a data-loss-
  prevention boundary: a plaintext DB password, an unprefixed high-entropy token,
  a base64 blob, or `PGPASSWORD=hunter2` all pass straight through. For the
  coordination bus — cross-session/cross-machine readable for 30 days — the real
  backstop for a credential this denylist misses is the delete/redact path
  (US-39.7), not this scan. Callers scan a bounded prefix per field, so a
  credential padded past the byte cap is rejected on length but may not fire the
  `secret_blocked` telemetry signal.

  The two lists live in separate repos with no shared compile-time source, so
  parity is a CONVENTION, not a guarantee: when you add a credential shape to one,
  add it to the other. (The bash script additionally scans for destructive shell
  commands — that is deletion-guard scope, not credential-denylist scope, and is
  intentionally absent here.) It targets high-confidence credential shapes (long,
  prefixed tokens / key material), not general "looks secret-ish" heuristics, to
  keep false positives near zero on ordinary coordination chatter.
  """

  # High-confidence credential patterns. Keep in sync (by convention) with the
  # credential shapes in claude-config/hooks/knowledge-capture.sh.
  @patterns [
    # Bearer <token>
    ~r/Bearer\s+[A-Za-z0-9_\-]{20,}/i,
    # OpenAI / Anthropic style sk- keys
    ~r/\bsk-[A-Za-z0-9_\-]{20,}/i,
    # Stripe secret keys (sk_live_ / sk_test_) and restricted keys (rk_live_/rk_test_)
    ~r/\b[rs]k_(live|test)_[A-Za-z0-9]{20,}/,
    # loopctl agent/orchestrator keys
    ~r/\blc_[A-Za-z0-9_\-]{20,}/,
    # GitHub personal-access / OAuth / server / refresh tokens
    ~r/\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}/i,
    # AWS access key id
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    # PEM private key blocks
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    # Slack tokens (bot/user/app/refresh/legacy)
    ~r/\bxox[baprs]-[A-Za-z0-9\-]{10,}/i,
    # JWTs (header.payload.signature, all base64url) — often bearer credentials
    ~r/\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}/,
    # URL-embedded credentials, e.g. postgres://user:s3cret@host, https://u:p@host
    ~r/\b[a-z][a-z0-9+.\-]*:\/\/[^\s:\/@]+:[^\s:\/@]+@/i
  ]

  # The instant the pattern set above last CHANGED. Bump this to `DateTime.utc_now()`
  # (rounded to the second) in the SAME commit that adds, removes, or loosens a pattern.
  #
  # It is the retroactivity lever for issue #499: `channel_posts.rescanned_at` records
  # when a post was last examined, and `Loopctl.Workers.ChannelPostRescanWorker` treats
  # any post scanned BEFORE this revision as eligible again. Without the bump, a newly
  # added credential shape would only ever apply to posts written after the deploy —
  # exactly the reactive-only behaviour #499 exists to remove. Forgetting to bump it is
  # not a correctness fault for NEW writes (the write-time gate uses the live patterns),
  # only a missed retroactive sweep.
  @revision ~U[2026-07-22 00:00:00Z]

  @doc """
  The instant the denylist pattern set last changed.

  Consumers that cache an "already scanned" marker (the coordination rescan) compare their
  marker against this to decide whether a previously-scanned row must be re-examined
  under the current patterns.
  """
  @spec revision() :: DateTime.t()
  def revision, do: @revision

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
