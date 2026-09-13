defmodule Loopctl.Delivery.InjectionDetector do
  @moduledoc """
  A deterministic prompt-injection detector for reporter-supplied text (issue #804).

  Pure: regular expressions over the text, no model call, no I/O. Any signal it returns
  ESCALATES the intake record and is written to the audit chain — it never filters,
  rewrites or drops the text, because a ticket that tries this is a security event worth
  a human seeing, not noise to hide.

  ## Signals

  - `instruction_override` — ignore/disregard/forget/override the previous (or system)
    instructions, "new instructions:", "from now on you must", asking to reveal the system
    prompt or credentials, or to keep something from the user.
  - `role_impersonation` — chat-template tokens (`<|im_start|>`), `[INST]` / `<<SYS>>`, a
    "system prompt:" line or heading, a line starting `Human:` or `Assistant:`, "you are
    now an AI / agent / unrestricted", jailbreak.
  - `tool_markup` — tool-call or XML-tag impersonation: tags named system,
    system-reminder, instructions, tool_use, tool_result, function_calls, invoke,
    parameter, `antml:*`, prompt or untrusted-data; JSON carrying a system, assistant or
    tool `role`, or a `tool_calls` / `function_call` key.
  - `fence_breakout` — the untrusted-block brackets or its label text, a code fence
    tagged system / prompt / instructions, an END- or BEGIN-of-input marker.
  - `agent_action` — a command an agent with commit authority would act on: `git push`,
    `gh pr merge`, `--no-verify`, `rm -rf`, a curl piped to a shell, "run the following
    command".
  - `hidden_characters` — zero-width characters, bidirectional controls, Unicode TAG
    characters, a soft hyphen, a zero-width joiner between letters or digits, or C0/C1
    control characters other than tab, newline and carriage return.
  - `hidden_markup` — content a human reader does not see but a model does: a non-empty
    HTML comment, or a markdown link-reference comment (`[//]: # (...)`).
  - `url_payload` — a `javascript:` / `data:` / `vbscript:` / `file:` URL, a URL whose
    decoded path or query matches another signal or carries a dozen words of prose, or a
    markdown image whose URL has a query string (an exfiltration beacon).
  - `user_agent_prose` — a browser user agent carrying prose: over 512 bytes, carrying
    another signal, containing a backtick, or three or more DISTINCT lexicon words anywhere
    in the string (see "User-agent signals" below).
  - `user_agent_non_ascii` — a user agent carrying any byte outside ASCII.
  - `user_agent_encoded` — a user agent carrying a percent-escape, an HTML entity, or a
    backslash `\\x` / `\\u` escape.
  - `user_agent_disguised` — a user agent whose letters are broken up by non-letters in a way
    no recorded real user agent token shows.

  Field-independent signals come from `scan/1`. The four `user_agent_*` signals come from
  `scan_user_agent/2`, because only the caller knows which text is a user agent.
  `structured_field_spoof` is reported by `Loopctl.Intake.TicketFacts`.

  ## Matching

  Every pattern is case-insensitive and runs over the text NFKC-normalised (so full-width
  letters fold to ASCII) with hidden characters both removed and replaced by a space, so
  `ig<U+200B>nore` and `ignore<U+200B>previous` both still match. `hidden_characters` and
  `hidden_markup` run over the raw text.

  ## User-agent signals

  **The contract: structural disguise signals plus a plain-word tripwire, with NO decoding.**

  Two review cycles built decoders — NFKC folding, mark stripping, look-alike character
  classes, spelled-out reassembly — and every one lost to the next encoding while adding
  false positives on real user agents (a Chrome build number read as `all`, an old
  `(Linux; U; en-us; ...)` token read as spelled-out). The one fix that held flagged the
  DISGUISE instead of undoing it, because a real user agent is a narrow, well-behaved
  string: visible ASCII, product tokens, platform comments and model codes. So each signal
  below asks "does this look like no real user agent?", never "what does this say once
  decoded?".

  - **`user_agent_non_ascii`** — any byte outside ASCII: accents, combining marks, small
    capitals, full-width and superscript characters, other scripts.
  - **`user_agent_encoded`** — a percent-escape `%XX`, an HTML entity (`&#NN;`, `&#xHH;`,
    `&name;`), or a backslash `\\xHH` / `\\uHHHH` escape.
  - **`user_agent_disguised`** (`user_agent_disguise/1` returns the measurements). The user
    agent is cut into tokens at whitespace and `; , / @ ( ) [ ]`. A token's LETTER SEGMENTS
    are its runs of ASCII letters. It fires on any of:
    1. a letter segment broken off by a character no real user agent carries (anything
       outside letters, digits, space and `( ) + , - . / : ; @ [ ] _ =`), as in `c#4n9e`;
    2. one BROKEN token of five or more letter segments;
    3. three or more BROKEN tokens;
    4. four or more consecutive tokens that are a single letter segment of one or two
       letters, as in `p, l, e, a, s, e`.

    A token is BROKEN when it has three or more letter segments and more than half of them
    are one to three letters long (`app-rov-e`), or exactly two segments, at least one of them
    short, joined by one digit, `-`, `_` or `.` (`y0u`, `n0w`, `th-is`). A token is EXEMPT
    when it has the shape of real platform data: an uppercase model or build code
    (`SM-G900F`, `KOT49H`, `QP1A.190711.020`, `FB_IAB`), a name followed by a version
    (`rv:1.8.1.20`, `x86_64`, `Win64`), a hexadecimal build hash (`2020.16.2.1-e99c70fff409`),
    a domain name (`www.google.com`), or the first locale tag in the user agent (`en-US`).
  - **`user_agent_prose`** — three or more DISTINCT lexicon words among the plain words: the
    string split at every character that is not an ASCII letter AND at every lowercase-to-
    uppercase boundary (`ApproveThisPull` is `approve`, `this`, `pull`), keeping words of
    three or more letters. The lexicon (`user_agent_lexicon/0`) is English function words
    plus agent-directed imperatives and nouns, and shares no word with the recorded real
    user agents except `agent` and `claude`.

  **Margins, asserted against `test/support/intake_fixtures/real_user_agents.json`** (the
  project's own recorded user agents, a published desktop and mobile user-agent list, and a
  set of old, smart-TV, in-app and regional user agents) and against a generated sweep of
  Chrome build numbers 1000-99999 in an Instagram in-app user agent:

  | measure | real maximum | fires at |
  |---|---|---|
  | lexicon words | 1 | 3 |
  | broken tokens | 1 | 3 |
  | letter segments in one broken token | 2 | 5 |
  | consecutive single-letter tokens | 2 | 4 |
  | odd-character breaks, non-ASCII bytes, escapes | 0 | 1 |

  Every real user agent fires nothing. The file proves nothing about a user agent outside it.

  A backtick anywhere in a user agent fires `user_agent_prose` on its own: no browser sends
  one, and `Loopctl.Intake.TicketFacts` has already removed a code span wrapping the whole
  value.

  **Known misses, pinned by a test that asserts they do NOT fire.** Without a decoder, a
  disguise the structure cannot tell from real platform data is invisible:

  - a paraphrase built from words outside the lexicon, and other languages;
  - a look-alike substitution too sparse for the disguise thresholds (`appr0ve this pull`,
    `appr0ve th1s pu11 request`: two broken tokens, and `pu11` has the shape of `Win64`);
  - UPPERCASE look-alike words (`APPR0VE TH1S PU11 REQU3ST`), which have the shape of model
    codes such as `SM-G900F`.

  They are allowed to be missed because three controls that do not depend on this heuristic
  bound the risk:

  1. **The implementer's input is built from the story only**
     (`Loopctl.Delivery.ImplementerInput`), so no user agent text reaches the session with
     commit authority.
  2. **Triage sees the user agent fenced as untrusted data** (`Loopctl.Delivery.Untrusted`).
  3. **The producer validates user-agent grammar** before filing the issue
     (home_care_billing#1506).

  The generic instruction, role, tool, fence and agent-action patterns still run over every
  user agent.

  ## Limits, written in rather than discovered later

  A pattern set is a tripwire, not a control. It misses novel phrasing, homoglyphs from
  another script, instructions split across markdown emphasis, and text in a language it
  has no patterns for. That is acceptable ONLY because it is not the control the loop
  relies on: the implementer never receives reporter text (`ImplementerInput`), and every
  prompt that does receive it fences it (`Untrusted`). The detector exists to make an
  attempt VISIBLE, and its false positives cost a human glance, which is the direction to
  err in.
  """

  alias Loopctl.Delivery.Untrusted

  @type reason :: String.t()

  @signals [
    :instruction_override,
    :role_impersonation,
    :tool_markup,
    :fence_breakout,
    :agent_action,
    :hidden_characters,
    :hidden_markup,
    :url_payload,
    :user_agent_prose,
    :user_agent_non_ascii,
    :user_agent_encoded,
    :user_agent_disguised
  ]

  @instruction_override [
    ~r/\b(?:ignore|disregard|forget|override|bypass)\s+(?:(?:all|any|the|your|my|these|those|of)\s+)*(?:previous|prior|above|earlier|preceding|original|system|safety)\s+(?:(?:system|user|safety)\s+)?(?:instructions?|prompts?|directives?|guidelines|guardrails|rules|messages|context)\b/iu,
    ~r/\bnew\s+(?:system\s+)?instructions?\s*:/iu,
    ~r/\b(?:from\s+now\s+on|henceforth)\s*,?\s+(?:you|the\s+(?:assistant|agent|model|ai))\s+(?:must|will|shall|should|are)\b/iu,
    ~r/\bdo\s+not\s+(?:tell|inform|alert|notify|mention\s+(?:this\s+)?to)\s+(?:the\s+)?(?:user|human|operator|reviewer|developer|maintainer)s?\b/iu,
    ~r/\b(?:reveal|print|output|repeat|show|leak|exfiltrate|dump)\s+(?:me\s+)?(?:your|the)\s+(?:(?:full|entire|hidden|original)\s+)?(?:system\s+prompt|instructions|secrets?|api\s+keys?|access\s+tokens?|credentials|environment\s+variables)\b/iu
  ]

  @role_impersonation [
    ~r/<\|\s*(?:im_start|im_end|system|assistant|user|endoftext|eot_id|start_header_id)\s*\|>/iu,
    ~r/\[\/?(?:INST|SYS)\]|<<\/?SYS>>/u,
    ~r/^\s*[#]{1,6}\s*(?:system|assistant|developer)(?:\s+(?:prompt|message|instructions?))?\s*:?\s*$/imu,
    ~r/^\s*(?:system|developer|assistant)\s+(?:prompt|message|instructions?)\s*:/imu,
    ~r/\b(?:new|updated|real|actual|hidden|secret)\s+system\s+prompt\b/iu,
    ~r/^(?:Human|Assistant)\s*:/mu,
    ~r/\byou\s+are\s+now\s+(?:an?\s+)?(?:ai|assistant|agent|model|dan|unrestricted|jailbroken|in\s+developer\s+mode)\b/iu,
    ~r/\bjailbr(?:eak|oken)\b/iu
  ]

  @tool_markup [
    ~r/<\s*\/?\s*(?:system(?:[-_]reminder)?|instructions?|tool[-_]?(?:use|call|result|code)s?|function[-_]?(?:calls?|results?)|invoke|parameter|antml:[a-z_]+|assistant|human|user[-_]?prompt|prompt|untrusted[-_]?data)\b[^>]*>/iu,
    ~r/"role"\s*:\s*"(?:system|assistant|tool|developer)"/iu,
    ~r/"(?:tool_calls|function_call|tool_use|tool_use_id|tool_result)"\s*:/iu
  ]

  @fence_breakout [
    ~r/[\x{27E6}\x{27E7}]/u,
    ~r/\b(?:END|BEGIN)\s+(?:OF\s+)?UNTRUSTED(?:\s+DATA)?\b|\bUNTRUSTED\s+DATA\b/iu,
    ~r/^\s*(?:```|~~~)\s*(?:system|prompt|instructions?|assistant|tool|antml)\b/imu,
    ~r/\b(?:END|BEGIN)\s+(?:OF\s+)?(?:USER\s+INPUT|REPORTER\s+(?:TEXT|INPUT)|TICKET\s+(?:TEXT|DATA)|SYSTEM\s+PROMPT|DOCUMENT)\b/iu
  ]

  @agent_action [
    ~r/\bgit\s+push\b/iu,
    ~r/\bgh\s+(?:pr|repo|secret|api)\s+(?:merge|delete|set|edit|create)\b/iu,
    ~r/--no-verify\b/iu,
    ~r/\brm\s+-[a-z]*r[a-z]*f|\brm\s+-[a-z]*f[a-z]*r/iu,
    ~r/\b(?:curl|wget)\s+[^\n|]*\|\s*(?:ba|z)?sh\b/iu,
    ~r/\b(?:run|execute)\s+(?:the\s+following|this|these)\s+(?:shell\s+|bash\s+|terminal\s+)?(?:command|commands|script)\b/iu
  ]

  @hidden_characters Regex.compile!(
                       "[" <>
                         Untrusted.hidden_character_class() <>
                         "\\x{0000}-\\x{0008}\\x{000B}\\x{000C}\\x{000E}-\\x{001F}\\x{007F}-\\x{009F}]" <>
                         "|(?<=[\\p{L}\\p{N}])\\x{200D}(?=[\\p{L}\\p{N}])",
                       "u"
                     )

  # Normalisation strips every invisible character, the joiner included: removing one
  # can only reveal a phrase, never hide one.
  @strip_hidden Regex.compile!("[\\x{200D}" <> Untrusted.hidden_character_class() <> "]", "u")

  @hidden_markup [
    ~r/<!--\s*\S[\s\S]*?-->/u,
    ~r/^\s*\[[^\]\n]*\]:\s*#\s*\(/mu
  ]

  @url ~r/\b(?:https?|javascript|data|vbscript|file):[^\s<>"'`]+/iu
  @dangerous_scheme ~r/\A(?:javascript|data|vbscript|file):/iu
  @image_beacon ~r/!\[[^\]\n]*\]\(\s*https?:\/\/[^)\s]*\?[^)\s]+\)/iu
  @url_prose_words 12

  @max_user_agent_bytes 512
  @ua_prose_threshold 3
  @ua_not_letter ~r/[^A-Za-z]+/
  @ua_camel_boundary ~r/(?<=[a-z])(?=[A-Z])/
  @ua_non_ascii ~r/[\x80-\xFF]/
  @ua_encoded ~r/%[0-9A-Fa-f]{2}|&#[0-9]+;|&#[xX][0-9A-Fa-f]+;|&[A-Za-z][A-Za-z0-9]*;|\\[xX][0-9A-Fa-f]{2}|\\u[0-9A-Fa-f]{4}/

  # user_agent_disguised: see "User-agent signals" in the moduledoc for each shape and margin.
  @ua_token_separators ~r/[\s;,\/@()\[\]]+/
  @ua_letter_segment ~r/[A-Za-z]+/
  @ua_odd_break ~r/[A-Za-z][^A-Za-z]*[^A-Za-z0-9 ()+,\-.\/:;@\[\]_=][^A-Za-z]*[A-Za-z]/
  @ua_code_shape ~r/\A[A-Z0-9._:\-]+\z/
  @ua_name_version_shape ~r/\A[A-Za-z]+[:_]?[0-9][0-9._]*\z/
  @ua_hex_shape ~r/\A[0-9a-f._\-]+\z/
  @ua_domain_shape ~r/\A[A-Za-z0-9\-]{2,}(?:\.[A-Za-z0-9\-]{2,})*\.[A-Za-z]{2,}\z/
  @ua_locale_shape ~r/\A[a-z]{2}[-_][a-z]{2}\z/i
  @ua_two_segment_word ~r/\A[^A-Za-z]*[A-Za-z]+[0-9._\-][A-Za-z]+[^A-Za-z]*\z/
  @ua_single_letter_token ~r/\A[A-Za-z]{1,2}\z/
  @ua_disguised_broken_tokens 3
  @ua_disguised_long_segments 5
  @ua_disguised_letter_run 4

  # English function words plus the imperatives and nouns an instruction to an agent is made
  # of. No two-letter word (they collide with locale tags and model codes), and no word the
  # recorded real user agents carry except `agent` and `claude`: a test binds it to that corpus.
  @ua_lexicon ~w(
    the this that these those and but then than for into onto with without are were been
    does did don doesn not all every each some its now here there please you your yours must
    should shall will would could may might just only also instead before after above below
    previous prior earlier again never always immediately today tonight
    approve approved merge merged ignore disregard forget instructions instruction system
    prompt prompts execute run delete remove drop deploy push commit review reviews skip
    bypass override assistant agent agents claude gpt llm model pull request change changes
    fix patch master main prod force verify admin root reveal print show tell secret secrets
    token tokens key keys password credentials grant access permission rule rules policy
    human operator ship release test tests safe done wait repo repository branch hook hooks
    ticket story issue yes trust trusted allow enable disable install hidden act pretend role
    respond reply answer write send upload download bash command commands sudo
  )

  @doc "The signal names this module can produce."
  @spec signals() :: [atom()]
  def signals, do: @signals

  @doc """
  Scans named text fields and returns the reasons that fired, as `"<signal>:<field>"`
  strings, sorted and unique. An empty list means nothing fired.

      scan([{"untrusted_title", title}, {"untrusted_body", body}])
  """
  @spec scan([{String.t(), String.t() | nil}]) :: [reason()]
  def scan(fields) when is_list(fields) do
    fields
    |> Enum.flat_map(fn {field, text} -> field |> scan_text(text) |> tag(field) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Scans a browser user agent, returning the `user_agent_*` reasons plus every
  field-independent signal the user agent carries.
  """
  @spec scan_user_agent(String.t(), String.t() | nil) :: [reason()]
  def scan_user_agent(_field, nil), do: []

  def scan_user_agent(field, user_agent) when is_binary(user_agent) do
    generic = scan_text(field, user_agent)
    prose = if user_agent_prose?(user_agent, generic), do: [:user_agent_prose], else: []
    non_ascii = if user_agent_non_ascii?(user_agent), do: [:user_agent_non_ascii], else: []
    encoded = if user_agent_encoded?(user_agent), do: [:user_agent_encoded], else: []
    disguised = if user_agent_disguised?(user_agent), do: [:user_agent_disguised], else: []

    (generic ++ prose ++ non_ascii ++ encoded ++ disguised)
    |> tag(field)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp tag(signals, field), do: Enum.map(signals, &"#{&1}:#{field}")

  defp scan_text(_field, nil), do: []
  defp scan_text(_field, ""), do: []

  defp scan_text(_field, text) when is_binary(text) do
    raw = String.replace_invalid(text, "\uFFFD")
    variants = normalised_variants(raw)

    textual =
      for {signal, patterns} <- textual_patterns(),
          Enum.any?(variants, fn variant -> Enum.any?(patterns, &Regex.match?(&1, variant)) end),
          do: signal

    raw_only =
      [
        {:hidden_characters, Regex.match?(@hidden_characters, raw)},
        {:hidden_markup, Enum.any?(@hidden_markup, &Regex.match?(&1, raw))},
        {:url_payload, Enum.any?(variants, &url_payload?/1)}
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    Enum.uniq(textual ++ raw_only)
  end

  defp textual_patterns do
    [
      instruction_override: @instruction_override,
      role_impersonation: @role_impersonation,
      tool_markup: @tool_markup,
      fence_breakout: @fence_breakout,
      agent_action: @agent_action
    ]
  end

  defp normalised_variants(raw) do
    nfkc =
      case :unicode.characters_to_nfkc_binary(raw) do
        binary when is_binary(binary) -> binary
        _ -> raw
      end

    Enum.uniq([
      Regex.replace(@strip_hidden, nfkc, ""),
      Regex.replace(@strip_hidden, nfkc, " ")
    ])
  end

  defp url_payload?(text) do
    Regex.match?(@image_beacon, text) or
      @url
      |> Regex.scan(text)
      |> Enum.any?(fn [url] -> url_carries_payload?(url) end)
  end

  defp url_carries_payload?(url) do
    Regex.match?(@dangerous_scheme, url) or
      (
        decoded = url |> url_tail() |> safe_decode()

        prose_words?(decoded, @url_prose_words) or
          Enum.any?(textual_patterns(), fn {_signal, patterns} ->
            Enum.any?(patterns, &Regex.match?(&1, decoded))
          end)
      )
  end

  # Everything after the authority: path, query and fragment.
  defp url_tail(url) do
    case String.split(url, "://", parts: 2) do
      [_scheme, rest] ->
        case String.split(rest, ["/", "?", "#"], parts: 2) do
          [_host, tail] -> tail
          [_host] -> ""
        end

      [_] ->
        url
    end
  end

  defp safe_decode(text) do
    URI.decode_www_form(text)
  rescue
    ArgumentError -> text
  end

  defp prose_words?(text, threshold) do
    text
    |> String.split(~r/[\s\/&=?#]+/u, trim: true)
    |> Enum.count(&Regex.match?(~r/\A\p{L}{2,}[,.;:!?]?\z/u, &1))
    |> Kernel.>=(threshold)
  end

  defp user_agent_prose?(user_agent, generic_signals) do
    byte_size(user_agent) > @max_user_agent_bytes or generic_signals != [] or
      String.contains?(user_agent, "`") or
      length(user_agent_lexicon_hits(user_agent)) >= @ua_prose_threshold
  end

  @doc "The number of distinct lexicon words at which `user_agent_prose` fires."
  @spec user_agent_prose_threshold() :: pos_integer()
  def user_agent_prose_threshold, do: @ua_prose_threshold

  @doc "The instruction lexicon `user_agent_lexicon_hits/1` counts words from."
  @spec user_agent_lexicon() :: [String.t()]
  def user_agent_lexicon, do: @ua_lexicon

  @doc """
  The plain words of a user agent, whole string and comments included: split at every
  character that is not an ASCII letter and at every lowercase-to-uppercase boundary, words of
  three or more letters, downcased. Nothing is decoded.
  """
  @spec user_agent_words(String.t()) :: MapSet.t(String.t())
  def user_agent_words(user_agent) when is_binary(user_agent) do
    user_agent
    |> String.replace_invalid()
    |> String.split(@ua_not_letter, trim: true)
    |> Enum.flat_map(&String.split(&1, @ua_camel_boundary, trim: true))
    |> Enum.filter(&(byte_size(&1) >= 3))
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  @doc "The distinct lexicon words a user agent contains, sorted."
  @spec user_agent_lexicon_hits(String.t()) :: [String.t()]
  def user_agent_lexicon_hits(user_agent) when is_binary(user_agent) do
    user_agent
    |> user_agent_words()
    |> Enum.filter(&lexicon_word?/1)
    |> Enum.sort()
  end

  @doc "Whether a user agent carries any byte outside ASCII."
  @spec user_agent_non_ascii?(String.t()) :: boolean()
  def user_agent_non_ascii?(user_agent) when is_binary(user_agent),
    do: Regex.match?(@ua_non_ascii, user_agent)

  @doc "Whether a user agent carries a percent-escape, an HTML entity or a backslash escape."
  @spec user_agent_encoded?(String.t()) :: boolean()
  def user_agent_encoded?(user_agent) when is_binary(user_agent),
    do: Regex.match?(@ua_encoded, user_agent)

  @doc "The thresholds `user_agent_disguised?/1` fires at."
  @spec user_agent_disguise_thresholds() :: map()
  def user_agent_disguise_thresholds do
    %{
      broken_tokens: @ua_disguised_broken_tokens,
      longest_broken_segments: @ua_disguised_long_segments,
      single_letter_run: @ua_disguised_letter_run
    }
  end

  @doc """
  The disguise measurements of a user agent. See "User-agent signals" in the moduledoc.
  """
  @spec user_agent_disguise(String.t()) :: %{
          odd_break: boolean(),
          broken_tokens: non_neg_integer(),
          longest_broken_segments: non_neg_integer(),
          single_letter_run: non_neg_integer()
        }
  def user_agent_disguise(user_agent) when is_binary(user_agent) do
    tokens =
      user_agent |> String.replace_invalid() |> String.split(@ua_token_separators, trim: true)

    {broken, _locale_seen} = Enum.flat_map_reduce(tokens, false, &broken_segments/2)

    %{
      odd_break: Enum.any?(tokens, &Regex.match?(@ua_odd_break, &1)),
      broken_tokens: length(broken),
      longest_broken_segments: Enum.max(broken, fn -> 0 end),
      single_letter_run: single_letter_run(tokens)
    }
  end

  @doc "Whether a user agent's letters are broken up in a way no real user agent shows."
  @spec user_agent_disguised?(String.t()) :: boolean()
  def user_agent_disguised?(user_agent) when is_binary(user_agent) do
    m = user_agent_disguise(user_agent)

    m.odd_break or m.broken_tokens >= @ua_disguised_broken_tokens or
      m.longest_broken_segments >= @ua_disguised_long_segments or
      m.single_letter_run >= @ua_disguised_letter_run
  end

  # Emits the letter-segment count of a BROKEN token, nothing for any other. The first
  # locale tag is exempt; a second one is judged like any other token.
  defp broken_segments(token, locale_seen) do
    cond do
      not locale_seen and Regex.match?(@ua_locale_shape, token) -> {[], true}
      platform_shape?(token) -> {[], locale_seen}
      true -> {broken_count(token), locale_seen}
    end
  end

  defp broken_count(token) do
    segments = @ua_letter_segment |> Regex.scan(token) |> List.flatten()
    count = length(segments)
    short = Enum.count(segments, &(byte_size(&1) <= 3))

    cond do
      count >= 3 and short * 2 > count -> [count]
      count == 2 and short >= 1 and Regex.match?(@ua_two_segment_word, token) -> [2]
      true -> []
    end
  end

  # Model and build codes, versions, build hashes and domains are how real user agents
  # break letters up.
  defp platform_shape?(token) do
    Regex.match?(@ua_code_shape, token) or Regex.match?(@ua_name_version_shape, token) or
      Regex.match?(@ua_domain_shape, token) or hex_build?(token)
  end

  defp hex_build?(token) do
    Regex.match?(@ua_hex_shape, token) and
      length(Regex.scan(~r/[0-9]/, token)) >= length(Regex.scan(~r/[a-f]/, token))
  end

  defp single_letter_run(tokens) do
    tokens
    |> Enum.chunk_by(&Regex.match?(@ua_single_letter_token, &1))
    |> Enum.filter(fn [token | _] -> Regex.match?(@ua_single_letter_token, token) end)
    |> Enum.map(&length/1)
    |> Enum.max(fn -> 0 end)
  end

  for word <- @ua_lexicon do
    defp lexicon_word?(unquote(word)), do: true
  end

  defp lexicon_word?(_word), do: false
end
