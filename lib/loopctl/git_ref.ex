defmodule Loopctl.GitRef do
  @moduledoc """
  Whether a string is a name this system will ever hand to git — ONE definition, read by every
  site that judges one (#874 review round 2, finding 1).

  It lived as a private predicate in `Loopctl.Delivery.DispatchPayload`, where it judged what a
  CALLER sent to `place_dispatch`. Then `POST /api/v1/intake/sources` began accepting
  `base_branch`, validated only by LENGTH, and `Loopctl.Delivery.TriageDispatcher` puts that
  stored value into a dispatch as BOTH `branch` and `base_branch` without going through
  `DispatchPayload.fill/3` — so `--upload-pack=/bin/sh` enrolled clean at 22 characters and
  reached git on a dev machine the first time an issue arrived on that repository.

  The remedy is not a second check next to the schema. A guard that enumerates dangerous
  spellings is the failure KB `909ba2b2` records, and a SECOND COPY of the rule is the same
  failure one step later: the two drift, and the weaker one is the one an attacker reaches. So
  the predicate moved here, both sites call it, and neither owns it.

  ## Narrower than git's own rules, on purpose

  Everything admitted here is a name git accepts. What each clause is for — a clause that can
  never fire is worse than no clause, because it reads as a guard while the case it names goes
  unchecked:

    * `@branch_name` bounds the CHARACTER SET and forces an alphanumeric first byte, so no name
      reaches git as an OPTION, and no shell metacharacter, whitespace or control character
      survives. Fully anchored (`\\A`/`\\z`), which the wire pattern on
      `RunnerJoin.branch_prefixes` cannot be — `^...$` admits a trailing newline under PCRE.
    * `..` is refused ANYWHERE, which no per-component rule catches: `a..b` is one component and
      breaks none of git's component rules while git refuses the ref.
    * the per-COMPONENT pass is where git's remaining rules actually live. Applied to a whole
      composed name, a `String.ends_with?(name, ".lock")` could not fire on a name that always
      ends with a `story-N-<id8>` suffix, while the cases it was written for — a prefix like
      `x.lock/` or `a/.b/`, both of which `@branch_name` admits because it allows `.` — went
      unchecked and produced a name git refuses. An EMPTY component is `//`, a leading `/` or a
      trailing one, so those need no clause of their own.

  LENGTH IS NOT JUDGED HERE, and that is deliberate: each caller bounds it against its own
  published number — `RunnerDispatch.max_branch_length/0` for a dispatch field, the column's own
  1..255 for `intake_sources.base_branch` — and folding one of those in here would make this
  module the place they silently disagree.
  """

  @branch_name ~r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}

  @doc """
  Whether `name` is a git ref name this system will hand to git.

  A non-binary is `false` rather than a raise: every caller judges values that arrived from
  outside — a request body, a database column — and a type error there is a refusal, not a bug.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name) do
    Regex.match?(@branch_name, name) and
      not String.contains?(name, "..") and
      name |> String.split("/") |> Enum.all?(&valid_component?/1)
  end

  def valid_name?(_name), do: false

  @doc """
  What a refused name violates, in words a 422 body can carry — never echoing the value, which
  is frequently something pasted into the wrong argument.
  """
  @spec refusal_message() :: String.t()
  def refusal_message do
    "must be a valid git branch name: letters, digits, '.', '_', '-' and '/' only, " <>
      "starting with a letter or digit, with no '..', no component starting with '.' and " <>
      "none ending in '.' or '.lock'"
  end

  defp valid_component?(component) do
    component != "" and
      not String.starts_with?(component, ".") and
      not String.ends_with?(component, [".lock", "."])
  end
end
