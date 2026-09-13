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
    in the string (see "User-agent prose" below).
  - `user_agent_spelled_out` — a user agent spelling a word out one letter at a time
    (`a.p.p.r.o.v.e.t.h.i.s`), eight letters or more.

  Field-independent signals come from `scan/1`. `user_agent_prose` and
  `user_agent_spelled_out` come from `scan_user_agent/2`, because only the caller knows which
  text is a user agent.
  `structured_field_spoof` is reported by `Loopctl.Intake.TicketFacts`.

  ## Matching

  Every pattern is case-insensitive and runs over the text NFKC-normalised (so full-width
  letters fold to ASCII) with hidden characters both removed and replaced by a space, so
  `ig<U+200B>nore` and `ignore<U+200B>previous` both still match. `hidden_characters` and
  `hidden_markup` run over the raw text.

  ## User-agent prose

  A user agent is judged by ONE measure over the WHOLE string, comments included: how many
  distinct words of an instruction lexicon it contains. It does not parse user-agent grammar.
  Three rounds of token-shape rules (bare tokens, joined runs, digit and version exemptions)
  each closed one bypass class and opened another, because a shape rule has to guess which
  characters an attacker will use to join words, and the attacker chooses them.

  `user_agent_lexicon_hits/1`:

  1. **Normalise.** NFKC folds full-width letters and superscript digits to ASCII. The words
     are then taken twice, once with combining marks (Unicode category M) stripped and once with them
     left as separators, so a mark decorating every letter and a mark joining two words are
     both undone.
  2. **Words.** Split on EVERY character that is not an ASCII letter. Digits, punctuation,
     symbols, whitespace and non-ASCII letters are all separators, so `approve-this`,
     `approve2`, `approve.this`, `pull/request` and `approve` U+01C0 `this` all yield their words.
     Segments of two or more letters are kept, downcased.
  3. **Spelled-out letters.** A maximal run of single letters each separated by exactly one
     non-letter character is joined and read as one word (`p.l.e.a.s.e` is `please`), and is
     also split at whitespace, so `p.l.e.a.s.e m.e.r.g.e` yields both words. A joined run
     of eight or more letters also fires `user_agent_spelled_out` on its own, since no real
     user agent spells anything out.
  4. **Digit-for-letter spelling.** A letters-and-digits run whose digits are all in `013457`
     is also read with them as `o i/l e a s t` (`appr0ve`, `th1s`, `pu11`), and counts only
     when that reading is a lexicon word. Runs shorter than four characters are never read,
     so a build suffix such as `A1` does not become `ai`.
  5. **Score** is the number of DISTINCT lexicon words found. Three or more fire.

  The lexicon (`user_agent_lexicon/0`) is English function words plus the imperatives and
  nouns an instruction to an agent is made of (`approve`, `merge`, `ignore`, `instructions`,
  `deploy`, `review`, `agent`, `pull`, `request`). It deliberately leaves out every word a real
  user agent carries (`like`, `mobile`, `compatible`, `version`, `build`, `preview`, `bot`,
  `on`, `one`, `edge`, `plus`, `help`), and a test fails if it ever shares a word with the
  recorded real user agents in `test/support/intake_fixtures/real_user_agents.json`.

  **Margin, asserted:** every recorded real user agent — desktop and mobile browsers, in-app
  webviews, crawlers, link expanders, and user agents carrying an email address or a URL —
  scores ZERO lexicon words, against a firing threshold of three.

  A backtick anywhere in a user agent fires on its own: no browser sends one, and
  `Loopctl.Intake.TicketFacts` has already removed a code span wrapping the whole value,
  so one that remains is inside it.

  **Known misses, pinned by a test that asserts they do NOT fire:** a paraphrase built from
  words outside the lexicon, the same instruction in another language, and a word spelled
  with a confusable letter from another script (a Cyrillic U+0430 inside `approve`). A
  lexicon is a tripwire and cannot enumerate those. It is allowed to miss them because three
  controls that do not depend on it bound the risk:

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
    :user_agent_spelled_out
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
  @ua_spelled_out_min_letters 8
  @ua_not_letter ~r/[^A-Za-z]+/
  @ua_spelled_out ~r/(?<![A-Za-z])[A-Za-z](?:[^A-Za-z][A-Za-z])+(?![A-Za-z])/u
  @ua_leet_run ~r/[A-Za-z0-9]+/
  @ua_leet_digits ~r/\A[A-Za-z013457]*\z/

  # English function words plus the imperatives and nouns an instruction to an agent is made
  # of. It must never contain a word a real user agent carries: a test binds it to the
  # recorded real corpus.
  @ua_lexicon ~w(
    the this that these those and or but if then than so to of for in into onto from with
    without by at as is are was were be been do does did don doesn not no all any every each
    some it its now here there please you your yours we our me my must should shall will would
    can could may might just only also instead before after above below previous prior earlier
    again never always immediately today tonight
    approve approved merge merged ignore disregard forget instructions instruction system
    prompt prompts execute run delete remove drop deploy push commit review reviews skip
    bypass override assistant agent agents claude gpt llm ai model pull request change changes
    code fix patch master main production prod force verify admin root reveal print show tell
    secret secrets token tokens key keys password credentials grant access permission rule
    rules policy user human operator ship release test tests safe done wait repo repository
    branch hook hooks ticket story issue pr ok yes trust trusted allow enable disable hidden
    act pretend role respond reply answer write send upload download install shell bash
    command commands sudo rm
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
  Scans a browser user agent, returning `user_agent_prose` and `user_agent_spelled_out`
  reasons plus every field-independent signal the user agent carries.
  """
  @spec scan_user_agent(String.t(), String.t() | nil) :: [reason()]
  def scan_user_agent(_field, nil), do: []

  def scan_user_agent(field, user_agent) when is_binary(user_agent) do
    generic = scan_text(field, user_agent)
    prose = if user_agent_prose?(user_agent, generic), do: [:user_agent_prose], else: []
    spelled = if user_agent_spelled_out?(user_agent), do: [:user_agent_spelled_out], else: []

    (generic ++ prose ++ spelled) |> tag(field) |> Enum.uniq() |> Enum.sort()
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
  Every candidate word of a user agent, whole string and comments included: the plain words,
  the spelled-out words, and the digit-for-letter readings that are lexicon words. See
  "User-agent prose" in the moduledoc.
  """
  @spec user_agent_words(String.t()) :: MapSet.t(String.t())
  def user_agent_words(user_agent) when is_binary(user_agent) do
    user_agent
    |> normalised_forms()
    |> Enum.flat_map(fn text ->
      plain_words(text) ++ spelled_out_words(text) ++ leet_words(text)
    end)
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

  @doc "Whether a user agent spells out a word of eight or more single letters."
  @spec user_agent_spelled_out?(String.t()) :: boolean()
  def user_agent_spelled_out?(user_agent) when is_binary(user_agent) do
    user_agent
    |> normalised_forms()
    |> Enum.flat_map(&spelled_out_runs/1)
    |> Enum.any?(&(String.length(&1) >= @ua_spelled_out_min_letters))
  end

  for word <- @ua_lexicon do
    defp lexicon_word?(unquote(word)), do: true
  end

  defp lexicon_word?(_word), do: false

  # NFKC, then the text twice: combining marks stripped, and marks left in place, where they
  # separate words like any other non-letter.
  defp normalised_forms(user_agent) do
    normalised =
      case user_agent |> String.replace_invalid() |> :unicode.characters_to_nfkc_binary() do
        binary when is_binary(binary) -> binary
        _ -> user_agent
      end

    Enum.uniq([Regex.replace(~r/\p{M}/u, normalised, ""), normalised])
  end

  defp plain_words(text) do
    text
    |> String.split(@ua_not_letter, trim: true)
    |> Enum.filter(&(byte_size(&1) >= 2))
    |> Enum.map(&String.downcase/1)
  end

  # Each run is read whole (`a.p-p.r.o.v.e` is `approve`) and also split at whitespace, so
  # `p.l.e.a.s.e m.e.r.g.e` yields `please` and `merge` as well as the joined run.
  defp spelled_out_words(text) do
    @ua_spelled_out
    |> Regex.scan(text)
    |> Enum.flat_map(fn [run] ->
      [run | String.split(run, ~r/\s/u, trim: true)]
      |> Enum.map(&(&1 |> String.replace(@ua_not_letter, "") |> String.downcase()))
      |> Enum.filter(&(byte_size(&1) >= 2))
    end)
  end

  defp spelled_out_runs(text) do
    @ua_spelled_out
    |> Regex.scan(text)
    |> Enum.map(fn [run] -> String.replace(run, @ua_not_letter, "") end)
  end

  # `appr0ve`, `th1s`, `pu11`: read the digits as letters, and keep only a lexicon word. A
  # run shorter than four characters is never read, so a build suffix such as `A1` cannot.
  defp leet_words(text) do
    for [run] <- Regex.scan(@ua_leet_run, text),
        byte_size(run) >= 4,
        String.match?(run, ~r/[A-Za-z]/) and String.match?(run, ~r/[0-9]/),
        String.match?(run, @ua_leet_digits),
        reading <- leet_readings(run),
        lexicon_word?(reading),
        uniq: true,
        do: reading
  end

  defp leet_readings(run) do
    base =
      run
      |> String.downcase()
      |> String.replace("0", "o")
      |> String.replace("3", "e")
      |> String.replace("4", "a")
      |> String.replace("5", "s")
      |> String.replace("7", "t")

    Enum.uniq([String.replace(base, "1", "i"), String.replace(base, "1", "l")])
  end
end
