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
  - `user_agent_prose` — a browser user agent that is over 512 bytes, carries another signal,
    contains a backtick, or carries three or more DISTINCT instruction words (see "User-agent
    tripwire" below).
  - `user_agent_non_ascii` — a user agent carrying any byte outside ASCII.

  Field-independent signals come from `scan/1`. The two `user_agent_*` signals come from
  `scan_user_agent/2`, because only the caller knows which text is a user agent.
  `structured_field_spoof` is reported by `Loopctl.Intake.TicketFacts`.

  ## Matching

  Every pattern is case-insensitive and runs over the text NFKC-normalised (so full-width
  letters fold to ASCII) with hidden characters both removed and replaced by a space, so
  `ig<U+200B>nore` and `ignore<U+200B>previous` both still match. `hidden_characters` and
  `hidden_markup` run over the raw text.

  ## User-agent tripwire

  **Neutralising a user agent is not this module's job.** The producer does it:
  home_care_billing#1506 writes a user agent into the issue only when it is valid user-agent
  token grammar of at most 512 bytes, and writes `unrecognised` otherwise. Triage then reads
  it fenced as untrusted data (`Loopctl.Delivery.Untrusted`), and the implementer never
  receives it at all, because its input is built from the story only
  (`Loopctl.Delivery.ImplementerInput`).

  **This module only ESCALATES, so a human sees an attempt.** A user agent escalates when it:

  - carries any byte outside ASCII (`user_agent_non_ascii`);
  - is over 512 bytes, contains a backtick, or matches a generic `scan/1` pattern
    (`user_agent_prose`);
  - carries three or more DISTINCT instruction words (`user_agent_prose`). The words are read
    three ways and the readings are UNIONED: split at non-letters and at lowercase-to-uppercase
    boundaries (`ApproveThisPull`); split at non-letters only, lowercased (`aPPROVE tHIS`); and
    split at every change of case (`APPROVEthisPULL`). Words of three or more letters count.
    The lexicon (`user_agent_lexicon/0`) is English function words plus agent-directed
    imperatives and nouns.

  **It deliberately does not try to see disguised or encoded wording.** Across #814 and #819,
  six review rounds measured user-agent-specific disguise heuristics — look-alike decoding,
  spelled-out reassembly, token-shape and escape detection — and each round found both new
  bypasses under a chosen encoding and new false alarms on real clients (AWS SDK `#`
  separators, IE toolbar braces, CFNetwork `%20`, random ids tripping on up to one run in
  five). A tripwire that fires on real clients and is still bypassable is worth less than a
  small, quiet one, so disguise is left to the producer's grammar check, where it is removed
  rather than guessed at.

  **Margins, asserted** against `test/support/intake_fixtures/real_user_agents.json`, a Chrome
  build sweep 1000-99999 in an Instagram in-app user agent, and 5,000 generated Apps Script
  ids and 5,000 lowercase UUIDs in real user-agent frames: every one fires nothing, and a real
  user agent carries at most TWO instruction words (the AWS CLI's `md/prompt#off
  md/command#s3.ls`) against a threshold of three.

  **Known misses, pinned by a test that asserts they fire no user-agent signal:**

  - a paraphrase built from words outside the lexicon;
  - the same instruction in another language;
  - disguised or encoded wording (neutralised at the producer, not detected here): look-alike
    characters, spelled-out or chunked letters, uppercase look-alikes, words glued in one
    case, percent-escapes and HTML entities.

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
    :user_agent_non_ascii
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
  @ua_case_change ~r/(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[a-z])/
  @ua_non_ascii ~r/[\x80-\xFF]/

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

    (generic ++ prose ++ non_ascii) |> tag(field) |> Enum.uniq() |> Enum.sort()
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
  The words of a user agent, whole string and comments included, as the UNION of three
  readings: split at non-letters and at lowercase-to-uppercase boundaries; split at non-letters
  only; and split at every change of case. Words of three or more letters, downcased. Nothing
  is decoded.
  """
  @spec user_agent_words(String.t()) :: MapSet.t(String.t())
  def user_agent_words(user_agent) when is_binary(user_agent) do
    runs = user_agent |> String.replace_invalid() |> String.split(@ua_not_letter, trim: true)

    [
      Enum.flat_map(runs, &String.split(&1, @ua_camel_boundary, trim: true)),
      runs,
      Enum.flat_map(runs, &String.split(&1, @ua_case_change, trim: true))
    ]
    |> List.flatten()
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

  for word <- @ua_lexicon do
    defp lexicon_word?(unquote(word)), do: true
  end

  defp lexicon_word?(_word), do: false
end
