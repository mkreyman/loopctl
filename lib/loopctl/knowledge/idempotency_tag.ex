defmodule Loopctl.Knowledge.IdempotencyTag do
  @moduledoc """
  The RESERVED tag namespace for per-source idempotency keys (#583).

  ## The problem this closes

  Harvest sourcers wrote a per-URL idempotency key as an ordinary tag
  (`url-<sha1>`) and did their "captured already?" existence check by querying
  that tag. LLM-generated TOPIC tags land in the same namespace — `url-design`,
  `url-routing`, `url-encoding` are all legal, plausible topic tags — so the
  mechanism that guarantees "captured exactly once" shared a namespace with free
  text a model invents at synthesis time. Nothing had broken yet; the shape was
  the defect.

  This module reserves a namespace that free text cannot land in:

      idem-<family>-<digest>

  where `<family>` is a short lowercase source family (`url`, `doc`, `book`,
  `yt`, ...) and `<digest>` is a lowercase sha1 hex of either 12 or 40
  characters. BOTH digest lengths are legal on purpose: the sourcers' suffix
  used to be the full 40-hex sha1 and is now truncated to 12, and a shape rule
  that recognised only the current era is exactly the drift bug that made
  pre-truncation captures invisible and got them re-extracted.

  The reservation is enforced at WRITE time, on the changeset (see
  `Loopctl.Knowledge.Article.create_changeset/2` and `update_changeset/2`), so
  it binds every writer — the API, the ingestion workers, the review worker, OKF
  import — rather than one call site. A tag that starts with the reserved prefix
  but does NOT match the full shape is REJECTED with a 422 naming the remedy; it
  is never silently re-prefixed, because rewriting a caller's tags makes the
  response body a lie about what was stored.

  ## What this is NOT

  Reserving the namespace is defense in depth, not an idempotency mechanism. A
  tag is caller-controlled data; the server-guaranteed key is the
  `articles.idempotency_key` column with its per-tenant unique index. Prefer
  that column. This module makes the tag namespace unambiguous for the readers
  that already depend on it — it does not make a tag authoritative.

  ## Legacy (pre-reservation) tags

  The reservation is FORWARD-looking. Articles captured before it carry the bare
  `<family>-<digest>` form, which is indistinguishable-by-prefix from a topic
  tag and so needs an independent read-side discriminator: `legacy?/1` matches
  the bare form by SHAPE, restricted to the known source families — see its
  docs for why that restriction is load-bearing rather than cosmetic.
  `promote_tags/2` moves a tag list to the reserved form;
  `mix loopctl.reserve_idempotency_tags` applies it across the corpus.

  Writing the bare legacy form is still ALLOWED — rejecting it would break the
  sourcers before the client half (mkreyman/claude-config#222) can adopt the
  reserved form, and the server half has to land first.
  """

  # Everything below is derived from these three pieces so the prefix, the
  # matchers, the promotion, the 422 message and the OpenAPI description can
  # never drift apart (the `claim:` reserved-namespace precedent in
  # `Loopctl.Coordination` ties its LIKE literal to its prefix the same way).
  @reserved_prefix "idem-"
  @family_source "[a-z][a-z0-9]{1,15}"
  @digest_source "[0-9a-f]{12}|[0-9a-f]{40}"

  # The source families the harvest sourcers write per-capture ids under. This
  # allowlist constrains the LEGACY matcher only, and the asymmetry is the
  # point: the reserved form is EXPLICITLY claimed by its writer, so any family
  # is legal there, while the legacy form is INFERRED by shape from an
  # unprefixed tag and so must be conservative. A bare `<anything>-<12|40 hex>`
  # also describes a git object id (`commit-<sha>`), a timestamp
  # (`release-202604150930`) and a zero-padded id (`ticket-000000012345`) —
  # promoting one of those fabricates a capture identity, and `--drop-legacy`
  # would then DELETE the original. An unknown family is left alone instead,
  # which costs only an unpromoted tag that still reads exactly as it did
  # before.
  #
  # This is NOT the question `Loopctl.Knowledge.ProvenanceTags` answers — which
  # prefixes are provenance rather than subject. The lists diverge because the
  # MATCHERS do: this one requires the digest half, so `email` is safe here and
  # `email-marketing` is left alone, while `topical?/1` and the search vector
  # match the bare PREFIX, where `email-`/`corpus-` would drop those real topics
  # the way a broad `p-` drops `p-value`. Its shape-aware
  # `admissible_suggestion?/1` has no such problem and DOES still admit a bare
  # `email-<digest>` — closable only by the SPLIT its moduledoc prescribes.
  #
  # `email` and `corpus` joined in #733, after the #583 census missed them. Both
  # ARE per-capture ids — `email-<sha1(message_id)[:12]>` and
  # `corpus-<sha1(member ids)>` — so promoting them invents no identity, which
  # is the only hazard this allowlist exists to prevent. Their sourcers
  # (claude-config's `extract_email_bodies.py` and `synthesize_batch.py`) emit
  # the RESERVED form directly now; what this list reaches is the BACKLOG of
  # bare tags written before that, which nothing else can promote. The digest
  # half still does the discriminating, so a topical `email-marketing` is left
  # alone. `art` was assessed at the same time and deliberately left out:
  # claude-config's `prune_kb.py` names it in a local list, but no sourcer emits
  # an `art-` capture id, and a family with no writer is exactly the guess this
  # allowlist refuses to make.
  #
  # `yt` is in the list but can never match, and the reason is worth keeping so
  # it is not re-litigated: a YouTube id is ELEVEN characters and
  # `@digest_source` accepts only 12 or 40, so length refuses every `yt-<id>`
  # whatever its alphabet. claude-config#222 reached the same "leave `yt-` alone"
  # answer from the WRONG premise, that a `yt-` tag is a grouping tag rather than
  # a capture identity; every family here is carried by all the atomic notes of
  # one capture, so that would rule out `url` and `doc` too. That is why the
  # YouTube sourcer emits its own reserved `idem-yt-<sha1(video_id)[:12]>`: the
  # server can never reach that family from the bare form.
  @legacy_families ~w(url doc book yt repo img file vid web email corpus)
  @legacy_family_source "(?:" <> Enum.join(@legacy_families, "|") <> ")"

  @reserved_regex Regex.compile!(
                    "^" <>
                      @reserved_prefix <>
                      "(" <>
                      @family_source <>
                      ")-(" <>
                      @digest_source <> ")\\z"
                  )
  @legacy_regex Regex.compile!("^(" <> @legacy_family_source <> ")-(" <> @digest_source <> ")\\z")

  @shape "#{@reserved_prefix}<family>-<digest>"
  @example "#{@reserved_prefix}url-7ebe1ca33431"

  @doc "The reserved tag prefix. Single source of truth for every derived form."
  @spec reserved_prefix() :: String.t()
  def reserved_prefix, do: @reserved_prefix

  @doc """
  The source families `legacy?/1` will promote from the bare form.

  Exposed so callers and tests read the enforced list rather than restating it —
  a second copy is how a family gets added here and silently missed there.
  """
  @spec legacy_families() :: [String.t()]
  def legacy_families, do: @legacy_families

  @doc "Human-readable shape of a well-formed reserved tag."
  @spec shape() :: String.t()
  def shape, do: @shape

  @doc "A well-formed reserved tag, for docs and error messages."
  @spec example() :: String.t()
  def example, do: @example

  @doc """
  Whether `tag` claims the reserved namespace (prefix only, shape not checked).

  This is the membership test the write guard uses: anything claiming the
  namespace must then satisfy `well_formed?/1` or be rejected.
  """
  @spec reserved?(term()) :: boolean()
  def reserved?(tag) when is_binary(tag), do: String.starts_with?(tag, @reserved_prefix)
  def reserved?(_), do: false

  @doc "Whether `tag` is a well-formed reserved idempotency tag."
  @spec well_formed?(term()) :: boolean()
  def well_formed?(tag) when is_binary(tag), do: Regex.match?(@reserved_regex, tag)
  def well_formed?(_), do: false

  @doc """
  Whether `tag` is a PRE-reservation idempotency tag: the bare `<family>-<digest>`
  form, matched by shape because it carries no prefix to match on.

  Deliberately conservative on BOTH halves, because the only consumer is a
  promotion that adds a reserved tag (and, on the second pass, deletes this one):

    * `<digest>` must be 12 or 40 lowercase hex characters, so `url-design` and
      `url-normalization` are not legacy tags;
    * `<family>` must be one of the families the sourcers emit
      (#{Enum.join(@legacy_families, ", ")}), so a hex-shaped suffix under some
      other family — `commit-<sha>`, `release-202604150930`,
      `ticket-000000012345` — is NOT a legacy tag either. Shape alone cannot
      tell those apart from a capture id, and guessing wrong invents a capture
      identity the article does not have.
  """
  @spec legacy?(term()) :: boolean()
  def legacy?(tag) when is_binary(tag), do: Regex.match?(@legacy_regex, tag)
  def legacy?(_), do: false

  @doc """
  The reserved form of a legacy tag.

  Returns `{:ok, reserved_tag}` for a legacy-shaped tag, `:error` otherwise
  (including for a tag that is ALREADY reserved — promoting twice is not a
  thing, which is what keeps the backfill idempotent).
  """
  @spec promote(term()) :: {:ok, String.t()} | :error
  def promote(tag) do
    if legacy?(tag), do: {:ok, @reserved_prefix <> tag}, else: :error
  end

  @doc """
  Moves a tag list to the reserved form.

  Every legacy-shaped tag gains its reserved counterpart; topical tags are left
  exactly as they are. Order is preserved and the result is deduplicated, so
  re-running is a no-op — a tag is never double-prefixed, because a reserved tag
  is not legacy-shaped.

  With `drop_legacy: true` the bare legacy tag is removed once its reserved
  counterpart is present. That is the SECOND pass, safe only after the client
  half (mkreyman/claude-config#222) stops querying the bare form; the default
  keeps both so the existing dedup reads keep working during the changeover.
  """
  @spec promote_tags([String.t()], keyword()) :: [String.t()]
  def promote_tags(tags, opts \\ []) when is_list(tags) do
    drop_legacy? = Keyword.get(opts, :drop_legacy, false)

    tags
    |> Enum.flat_map(fn tag ->
      case promote(tag) do
        {:ok, reserved} when drop_legacy? -> [reserved]
        {:ok, reserved} -> [tag, reserved]
        :error -> [tag]
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  The validation error for a tag that claims the reserved namespace without
  matching its shape. Names the remedy, like the `claim:` prefix message does.
  """
  @spec reserved_violation_message() :: String.t()
  def reserved_violation_message do
    "tag %{tag} claims the reserved idempotency namespace \"#{@reserved_prefix}\" " <>
      "but is not a well-formed idempotency tag; it must be #{@shape} where <digest> " <>
      "is a 12- or 40-character lowercase hex digest (e.g. #{@example}), or drop the " <>
      "\"#{@reserved_prefix}\" prefix if this is a topical tag"
  end

  @doc """
  The reserved-namespace contract as published to API callers. Interpolated into
  the OpenAPI `tags` description on create and update so the spec and the
  enforcement cannot state different rules.
  """
  @spec contract_description() :: String.t()
  def contract_description do
    "The \"#{@reserved_prefix}\" prefix is RESERVED for per-source idempotency " <>
      "keys: a tag starting with it must be #{@shape} (<digest> = 12 or 40 " <>
      "lowercase hex chars, e.g. #{@example}) or the write is rejected 422 — " <>
      "it is never silently rewritten. Topical tags must not use the prefix. " <>
      "For server-guaranteed idempotency prefer the idempotency_key field, " <>
      "which has a per-tenant unique index; a tag is caller-controlled data."
  end
end
