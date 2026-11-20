defmodule LoopctlRunner.ContractVersionCanaryTest do
  @moduledoc """
  The vendored contract's version is stated in PROSE in three places, and nothing else pins them.

  `contract_test.exs` and `control_test.exs` assert the version the JSON carries, so a vendoring
  that bumps `priv/runner_contract/v1.json` turns those red and they get fixed. The prose does
  not move with them: the README, the design and `Contract`'s moduledoc would go on naming the
  contract this repo USED to hold — a held copy that states a falsehood, which is the failure the
  1.12.0 vendoring existed to end, one level up.

  Each site is matched on the PHRASE that states the current version, never on a bare semver.
  These files also name OTHER versions in passing, and those are correct: a canary that refused
  them is one the next session deletes rather than fixes. That the anchors can tell the two apart
  is proved against the lines READ OUT OF those files, never against a copy of them kept here —
  a held copy checked by nothing is what this whole test is for.

  ## The bound, which is deliberate

  This canary covers the three files `@sites` names, and NOTHING ELSE. A fourth shipped file that
  states the contract version is not caught: add it to `@sites` when you write it. A sweep of the
  tracked files was built and cut — to be correct it needed per-site pinning, distinct-site
  counting, an enumeration of root files and git on PATH, and those four parts produced more
  defects in one review round than the drift they were guarding against. A guard whose own failure
  modes outnumber the defect it prevents is the one people delete when it misfires. Three anchors
  that cannot be wrong beat a sweep that can, and a bound stated plainly beats an unreliable
  guard. Do not re-grow it without a fourth site that actually drifted.

  A missing anchor FAILS rather than passing quietly, and so does a site this file can no longer
  read. A reworded or renamed site would otherwise leave this test green forever while checking
  nothing.
  """

  use ExUnit.Case, async: true

  alias LoopctlRunner.Contract

  @root Path.expand("..", __DIR__)

  # {file, the phrase as it reads with the version in it, the regex capturing the version}.
  # The phrase is quoted back in the failure message: someone hits this mid-vendor and needs to
  # know which line to edit without opening this file.
  @sites [
    {"README.md", "on runner contract <version>.", ~r/on runner contract (\d+\.\d+\.\d+)/},
    {"docs/agent-delivery-loop.md", "(`contract_version` <version>), vendored",
     ~r/\(`contract_version` (\d+\.\d+\.\d+)\)/},
    {"lib/loopctl_runner/contract.ex", "(JSON Schema 2020-12, `x-contract-version` <version>).",
     ~r/`x-contract-version` (\d+\.\d+\.\d+)/}
  ]

  # A semver that is not part of a longer dotted number, used to find the versions a site names
  # ASIDE from the one it states. The trailing guard rejects a further `.<digit>` rather than any
  # period: a version at the end of a sentence is followed by one, and rejecting that dropped
  # whole lines out of the negative cases below.
  @semver ~r/(?<!\d)(?<!\d\.)\d+\.\d+\.\d+(?!\d)(?!\.\d)/

  test "every prose statement of the contract version names the version actually vendored" do
    want = Contract.version()

    findings = for site <- @sites, finding = check(site, want), do: finding

    assert findings == [],
           """
           The vendored contract (priv/runner_contract/v1.json) is #{want}, and the prose does not
           say so. Edit each file below.

           #{Enum.join(findings, "\n")}
           """
  end

  test "each anchor matches exactly once, so a second statement cannot go unchecked" do
    for {rel, phrase, pattern} <- @sites do
      # Counted over the whole file rather than per line: the canary above reports the FIRST
      # match, so a second statement anywhere — including further along the same line — would
      # be free to go stale.
      matches = length(Regex.scan(pattern, body!(rel)))

      assert matches == 1, count_message(rel, phrase, matches)
    end
  end

  test "the anchors match the version STATEMENT and not a version a file names in passing" do
    passing =
      for {rel, _phrase, pattern} <- @sites,
          {no, line} <- other_version_lines(rel, pattern),
          do: {rel, no, line}

    # Asserted across the sites together, not one by one. An ordinary prose cleanup can leave any
    # single file naming no other version, and turning that into a red whose only remedy is
    # editing this test is how a canary gets deleted. What the sites contribute is also uneven:
    # the design doc and `Contract` name older CONTRACT versions, while README's other versions
    # are mostly another product's releases (loopctl-mcp-server), which @semver cannot tell apart
    # from a contract version. That is fine for what is being refuted here — a line naming any
    # version that is not the statement is a valid negative case — but it means README alone does
    # not demonstrate the property.
    assert passing != [],
           "no site names a version other than the one it states, so nothing here proves the " <>
             "anchors can tell a statement from a passing mention. If the prose really has no " <>
             "other version left anywhere, this test has nothing to prove: delete it rather " <>
             "than weakening the anchors to give it something."

    for {rel, no, line} <- passing, {owner, _phrase, pattern} <- @sites do
      refute line =~ pattern,
             "the #{owner} anchor #{Regex.source(pattern)} matches #{rel}:#{no}, which names a " <>
               "version in passing rather than stating the one vendored: #{String.trim(line)}"
    end
  end

  # Every line of a site that names a version EXCEPT the one the anchor reads. Derived from the
  # file on every run: a copy of these lines kept here would be a second held copy, free to drift
  # from the files it claims to describe, which is the defect this canary exists to catch.
  defp other_version_lines(rel, pattern) do
    lines = rel |> body!() |> String.split("\n") |> Enum.with_index(1)
    anchor = Enum.find_value(lines, fn {line, no} -> if line =~ pattern, do: no end)

    for {line, no} <- lines, no != anchor, line =~ @semver, do: {no, line}
  end

  defp check({rel, phrase, pattern}, want) do
    case read(rel) do
      {:ok, body} -> stated(rel, phrase, pattern, want, body)
      {:error, reason} -> "  " <> unreadable(rel, reason) <> " Its anchor is #{inspect(phrase)}."
    end
  end

  defp stated(rel, phrase, pattern, want, body) do
    hit =
      body
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.find_value(fn {line, no} ->
        case Regex.run(pattern, line) do
          [_, stated] -> {no, stated}
          nil -> nil
        end
      end)

    case hit do
      {_no, ^want} ->
        nil

      {no, stated} ->
        "  #{rel}:#{no} states #{stated}, should state #{want} — the line reads: #{phrase}"

      nil ->
        "  #{rel} no longer states the contract version anywhere (nothing matches " <>
          "#{inspect(Regex.source(pattern))}). Restate it there, or re-anchor this canary on " <>
          "whatever phrase replaced #{inspect(phrase)} — do not delete the site."
    end
  end

  # Zero and two are opposite problems, and telling a reader to remove a duplicate that does not
  # exist is how a canary gets deleted instead of fixed. Zero is also the likelier of the two: a
  # reflow that splits the anchor across a line break lands here.
  defp count_message(rel, phrase, 0) do
    "#{rel} no longer states the contract version on any single line — a reflow or a rewording " <>
      "will do this. Restate it as #{inspect(phrase)}, or re-anchor this site in @sites."
  end

  defp count_message(rel, phrase, matches) do
    "#{rel} states the contract version #{matches} times; the canary above checks only the " <>
      "first, so the rest are free to go stale. Keep one statement (#{phrase}), or add the " <>
      "others to @sites."
  end

  defp unreadable(rel, reason) do
    "#{rel} cannot be read (#{inspect(reason)}). If the site moved, point @sites at its new " <>
      "path and keep its anchor — do not drop the site."
  end

  defp body!(rel) do
    case read(rel) do
      {:ok, body} -> body
      {:error, reason} -> flunk(unreadable(rel, reason))
    end
  end

  defp read(rel), do: @root |> Path.join(rel) |> File.read()
end
