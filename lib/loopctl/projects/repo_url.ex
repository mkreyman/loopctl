defmodule Loopctl.Projects.RepoUrl do
  @moduledoc """
  The one parser of a project's `repo_url`, shared by `Loopctl.Projects.resolve_project/2`
  and the `projects.repo_key` column (US-52.1), so the resolver and the uniqueness index can
  never disagree about which repo a URL names.

  `key/1` is the repo's identity: `host/owner/repo`, lowercased, with the https, ssh and
  scp-like spellings, a `.git` suffix, a trailing slash and an explicit port all collapsed. A
  bare `owner/repo` has no host and is keyed on `github.com`, the host every intake source
  names (`repo_full_name` is a GitHub `owner/name`).
  """

  @default_host "github.com"

  @doc "The repo's identity key, or nil when the URL names no `owner/repo` path."
  @spec key(String.t() | nil) :: String.t() | nil
  def key(url) do
    case ref(url) do
      nil -> nil
      {host, path} -> "#{host || @default_host}/#{path}"
    end
  end

  @doc "Lowercase, strip a trailing `/` then a trailing `.git` (then any residual `/`)."
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.downcase()
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.trim_trailing("/")
  end

  @doc """
  Parses a repo URL, ssh spec or bare `owner/repo` into `{host, path}`, so the ssh, https and
  bare forms compare equal while the FULL namespace path is kept (GitLab subgroups
  `group-a/team/api` and `group-b/team/api` stay distinct). `host` is nil for bare input. nil
  when no `owner/repo`-shaped path (two segments or more) can be derived.
  """
  @spec ref(String.t() | nil) :: {String.t() | nil, String.t()} | nil
  def ref(nil), do: nil

  def ref(url) when is_binary(url) do
    without_scheme =
      url
      |> normalize()
      # strip a URL scheme (https://, http://, git://, ssh://, ...)
      |> String.replace(~r{^[a-z][a-z0-9+.\-]*://}, "")
      # strip a leading userinfo (git@, user@) so scp-like specs parse
      |> String.replace(~r{^[^/@]+@}, "")
      # drop an explicit host :port (https://host:443/..., ssh://host:22/...) so
      # a port-carrying URL still compares equal to the same repo stored without
      # the port. Only a numeric :<digits> right after the host is a port.
      |> String.replace(~r{^([^/:]+):\d+(/|$)}, "\\1\\2")
      # scp-like "host:owner/repo" -> "host/owner/repo". Convert only the FIRST
      # colon (the host/path separator) so a colon later in the path is intact.
      |> String.replace(":", "/", global: false)

    case String.split(without_scheme, "/", trim: true) do
      [first | rest] = segments when rest != [] ->
        # Treat the leading segment as a host ONLY when it looks like a hostname
        # (contains a dot) AND the segments after it still form a >= 2-segment
        # "owner/repo" path. This stops a bare, host-less "owner.with.dot/repo"
        # from being misread as host="owner.with.dot" with a single remaining
        # segment (which would drop an otherwise-valid path and return nil).
        {host, path_segments} =
          if host_segment?(first) and match?([_, _ | _], rest) do
            {first, rest}
          else
            {nil, segments}
          end

        case path_segments do
          [_, _ | _] -> {host, Enum.join(path_segments, "/")}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # A leading segment LOOKS like a hostname when it contains a dot (github.com,
  # gitlab.com, git.example.com). The caller additionally requires a >= 2-segment
  # remaining path before treating it as a host, so a dotted bare owner does not
  # get misclassified.
  defp host_segment?(segment), do: String.contains?(segment, ".")
end
