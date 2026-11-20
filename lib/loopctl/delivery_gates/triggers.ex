defmodule Loopctl.DeliveryGates.Triggers do
  @moduledoc """
  Parses and verifies the Gate B trigger configuration.

  The trigger DATA is configuration, never source: loopctl is public, and the list is a map
  of which paths skip human review. This module receives the document as a binary together
  with the SHA-256 the operator pinned for it, and either returns a fully validated trigger
  set or an error. It never returns a partial or empty one.

  ## Document shape

      {
        "version": 2,
        "repos": {
          "owner/repo": {
            "effect_paths": ["priv/rates/**", "lib/app/payments/**"],
            "independent_paths": ["lib/app_web/router.ex", "lib/**/data_migrations/**"],
            "independent_checks": ["e2e"],
            "limits": {"max_files": 12, "max_changed_lines": 1000}
          }
        }
      }

  Every key is required, no other key is accepted, both pattern lists must be non-empty,
  `independent_checks` must be a non-empty list of check names, and both limits must be
  positive integers. An unknown key is an error rather than something to ignore, because a
  misspelled `"efect_paths"` beside a correct one would otherwise be a trigger list nobody
  reads.

  `independent_checks` names the CI jobs that must be green at a pull request's head before
  a change touching an `independent_paths` pattern (or any change to a control-plane
  repository) merges (US-52.12, `Loopctl.Delivery.MergePrecondition.independent_verification/3`).
  `local-gate` is refused there: it is a status whoever pushed can post, and
  `Loopctl.Delivery.CiEvidence` never looks it up, so naming it would be a list that judges
  nothing.

  ## Only version 2

  Version 2 is the only version read (US-52.12). Any other version is
  `{:unsupported_version, v}`, and a repository key this module does not name is
  `{:unknown_key, ["repos", repo, key]}`, so a document written for another version's
  meaning is refused rather than read under this one.

  The checksum is verified against the raw bytes BEFORE the document is decoded, so a
  document that does not match what the operator pinned is never interpreted at all.
  """

  alias Loopctl.DeliveryGates.Glob
  alias Loopctl.DeliveryGates.RepoTriggers
  alias Loopctl.Intake.Source

  @supported_versions [2]
  @top_keys ~w(version repos)
  @repo_keys ~w(effect_paths independent_paths independent_checks limits)
  @limit_keys ~w(max_files max_changed_lines)
  @repo_name ~r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}
  @sha256_hex ~r/\A[0-9a-f]{64}\z/

  @enforce_keys [:version, :sha256, :repos]
  defstruct [:version, :sha256, :repos]

  @type t :: %__MODULE__{
          version: pos_integer(),
          sha256: String.t(),
          repos: %{String.t() => RepoTriggers.t()}
        }

  @type key_path :: [String.t()]

  @type error ::
          :missing_config
          | :invalid_checksum_format
          | :checksum_mismatch
          | :invalid_json
          | {:unsupported_version, term()}
          | {:not_an_object, key_path()}
          | {:missing_key, key_path()}
          | {:unknown_key, key_path()}
          | {:empty_repos, key_path()}
          | {:invalid_repo_name, String.t()}
          | {:empty_patterns, key_path()}
          | {:invalid_patterns, key_path()}
          | {:invalid_pattern, key_path(), term()}
          | {:empty_checks, key_path()}
          | {:invalid_checks, key_path()}
          | {:invalid_limit, key_path()}

  @doc """
  Verifies `binary` against `expected_sha256_hex` and parses it.

  `nil` or an empty binary is `{:error, :missing_config}`. The expected checksum is
  64 hex characters, case-insensitive.
  """
  @spec parse(term(), term()) :: {:ok, t()} | {:error, error()}
  def parse(binary, expected_sha256_hex) do
    with :ok <- present(binary),
         {:ok, expected} <- normalize_checksum(expected_sha256_hex),
         :ok <- verify_checksum(binary, expected),
         {:ok, doc} <- decode(binary),
         :ok <- exact_keys(doc, @top_keys, []),
         {:ok, version} <- version(doc["version"]),
         {:ok, repos} <- repos(doc["repos"]) do
      {:ok, %__MODULE__{version: version, sha256: expected, repos: repos}}
    end
  end

  @doc """
  The triggers for one repository, or `:error` when the configuration does not name it.
  """
  @spec fetch_repo(t(), term()) :: {:ok, RepoTriggers.t()} | :error
  def fetch_repo(%__MODULE__{repos: repos}, repo) when is_binary(repo), do: Map.fetch(repos, repo)
  def fetch_repo(%__MODULE__{}, _repo), do: :error

  defp present(binary) when is_binary(binary) and binary != "", do: :ok
  defp present(_binary), do: {:error, :missing_config}

  defp normalize_checksum(hex) when is_binary(hex) do
    hex = String.downcase(hex)
    if Regex.match?(@sha256_hex, hex), do: {:ok, hex}, else: {:error, :invalid_checksum_format}
  end

  defp normalize_checksum(_hex), do: {:error, :invalid_checksum_format}

  defp verify_checksum(binary, expected) do
    actual = :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
    if actual == expected, do: :ok, else: {:error, :checksum_mismatch}
  end

  defp decode(binary) do
    case Jason.decode(binary) do
      {:ok, doc} -> {:ok, doc}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp exact_keys(map, keys, path) when is_map(map) do
    present = Map.keys(map)

    cond do
      missing = Enum.find(keys, &(&1 not in present)) ->
        {:error, {:missing_key, path ++ [missing]}}

      unknown = Enum.find(present, &(&1 not in keys)) ->
        {:error, {:unknown_key, path ++ [unknown]}}

      true ->
        :ok
    end
  end

  defp exact_keys(_value, _keys, path), do: {:error, {:not_an_object, path}}

  defp version(v) when is_integer(v) and v in @supported_versions, do: {:ok, v}
  defp version(v), do: {:error, {:unsupported_version, v}}

  defp repos(repos) when is_map(repos) and map_size(repos) == 0,
    do: {:error, {:empty_repos, ["repos"]}}

  defp repos(repos) when is_map(repos) do
    repos
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {name, entry}, {:ok, acc} ->
      case repo(name, entry) do
        {:ok, triggers} -> {:cont, {:ok, Map.put(acc, name, triggers)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp repos(_repos), do: {:error, {:not_an_object, ["repos"]}}

  defp repo(name, entry) do
    path = ["repos", name]

    with :ok <- repo_name(name),
         :ok <- exact_keys(entry, @repo_keys, path),
         {:ok, effect} <- patterns(entry["effect_paths"], path ++ ["effect_paths"]),
         {:ok, independent} <-
           patterns(entry["independent_paths"], path ++ ["independent_paths"]),
         {:ok, checks} <- checks(entry["independent_checks"], path ++ ["independent_checks"]),
         :ok <- exact_keys(entry["limits"], @limit_keys, path ++ ["limits"]),
         {:ok, max_files} <- limit(entry["limits"]["max_files"], path ++ ["limits", "max_files"]),
         {:ok, max_lines} <-
           limit(entry["limits"]["max_changed_lines"], path ++ ["limits", "max_changed_lines"]) do
      {:ok,
       %RepoTriggers{
         effect_paths: effect,
         independent_paths: independent,
         independent_checks: checks,
         max_files: max_files,
         max_changed_lines: max_lines
       }}
    end
  end

  defp repo_name(name) do
    if Regex.match?(@repo_name, name), do: :ok, else: {:error, {:invalid_repo_name, name}}
  end

  defp patterns([], path), do: {:error, {:empty_patterns, path}}

  defp patterns(list, path) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn pattern, {:ok, acc} ->
      case Glob.compile(pattern) do
        {:ok, glob} -> {:cont, {:ok, [glob | acc]}}
        {:error, :invalid_pattern} -> {:halt, {:error, {:invalid_pattern, path, pattern}}}
      end
    end)
    |> case do
      {:ok, globs} -> {:ok, Enum.reverse(globs)}
      error -> error
    end
  end

  defp patterns(_value, path), do: {:error, {:invalid_patterns, path}}

  # A non-empty list of non-empty check names, never `local-gate` (see the moduledoc).
  defp checks([], path), do: {:error, {:empty_checks, path}}

  defp checks(list, path) when is_list(list) do
    if Enum.all?(list, &check_name?/1),
      do: {:ok, Enum.uniq(list)},
      else: {:error, {:invalid_checks, path}}
  end

  defp checks(_value, path), do: {:error, {:invalid_checks, path}}

  defp check_name?(name) when is_binary(name),
    do: String.trim(name) != "" and name != Source.local_gate()

  defp check_name?(_name), do: false

  defp limit(value, _path) when is_integer(value) and value > 0, do: {:ok, value}
  defp limit(_value, path), do: {:error, {:invalid_limit, path}}
end
