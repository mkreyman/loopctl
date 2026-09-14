defmodule Loopctl.DeliveryGates.Measurement.ArtifactPins do
  @moduledoc """
  The checkable half of `docs/measurements/README.md`'s cross-run rule (issue #828, round-3
  finding 6).

  The rule is that two runs may be compared ONLY when their pinning fields are identical and
  quoted beside the comparison. An absolute ban was unenforceable and also wrong: it made the
  `--head`/`--expect-corpus` machinery pointless, since a correctly pinned pair is exactly what
  those flags exist to produce. What IS mechanical is the precondition — every artifact must
  CARRY its pins, and two artifacts of the same gate that agree on the pin they are keyed by
  must agree on the rest.

  ## What it checks, and what it deliberately cannot

  - Every artifact carries the pins its gate defines (`@required_pins`). An artifact with no
    head sha, or a ticket corpus with no fingerprint, is not comparable with anything.
  - Two Gate B artifacts sharing a `head` must agree on `trigger_fingerprint` and
    `trigger_shape` — same corpus, different configuration, is a comparison that would read as
    like-for-like and is not one.
  - Two Gate A artifacts sharing a `corpus_fingerprint` must agree on `corpus`.
  - The date in the filename is the UTC date of `meta.generated_at`, which is the only
    convention a reader has for pairing a `.json` with its `.md`.

  It cannot check whether a comparison in PROSE quoted its pins — nothing mechanical can read
  that. What it removes is the case where the pins were never recorded, or were recorded and
  disagree, which is every case where the prose could not have been right.
  """

  @type finding :: {Path.t(), String.t()}

  @required_pins %{
    "B" => [:head, :trigger_fingerprint, :trigger_shape, :repo, :generated_at],
    "A" => [:corpus, :corpus_fingerprint, :tickets, :generated_at]
  }

  # Artifacts of one gate that agree on the KEY must agree on every companion.
  @pin_groups %{
    "B" => {:head, [:trigger_fingerprint, :trigger_shape, :repo]},
    "A" => {:corpus_fingerprint, [:corpus]}
  }

  @filename ~r/\Agate_(?<gate>[ab])_(?<date>\d{4}-\d{2}-\d{2})\.json\z/

  @doc """
  Checks every `gate_*_<date>.json` under `dir`. Returns `{:ok, count}` or `{:error, findings}`.

  An EMPTY directory is `{:ok, 0}` and not an error: a repository with no measurements yet is a
  legitimate state, and failing on it would make the check impossible to introduce.
  """
  @spec check(Path.t()) :: {:ok, non_neg_integer()} | {:error, [finding()]}
  def check(dir) do
    paths = dir |> Path.join("gate_*.json") |> Path.wildcard() |> Enum.sort()

    {artifacts, read_findings} =
      Enum.reduce(paths, {[], []}, fn path, {ok, bad} ->
        case load(path) do
          {:ok, artifact} -> {[artifact | ok], bad}
          {:error, finding} -> {ok, [finding | bad]}
        end
      end)

    artifacts = Enum.reverse(artifacts)

    findings =
      Enum.reverse(read_findings) ++
        Enum.flat_map(artifacts, &missing_pins/1) ++
        Enum.flat_map(artifacts, &filename_date/1) ++
        group_disagreements(artifacts)

    if findings == [], do: {:ok, length(paths)}, else: {:error, findings}
  end

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"gate" => gate, "meta" => meta}} when is_map(meta) <- Jason.decode(body),
         true <- Map.has_key?(@required_pins, gate) do
      {:ok, %{path: path, gate: gate, meta: meta}}
    else
      {:error, %Jason.DecodeError{}} -> {:error, {path, "is not valid JSON"}}
      {:error, reason} -> {:error, {path, "cannot be read: #{:file.format_error(reason)}"}}
      _other -> {:error, {path, "has no recognised `gate` and `meta` object"}}
    end
  end

  defp missing_pins(%{path: path, gate: gate, meta: meta}) do
    for pin <- Map.fetch!(@required_pins, gate),
        blank?(Map.get(meta, to_string(pin))),
        do: {path, "carries no `meta.#{pin}`, so it is not comparable with any other run"}
  end

  defp filename_date(%{path: path, meta: meta}) do
    with %{"date" => date} <- Regex.named_captures(@filename, Path.basename(path)),
         generated when is_binary(generated) <- Map.get(meta, "generated_at"),
         false <- String.starts_with?(generated, date) do
      [
        {path,
         "is named for #{date} but was generated at #{generated} — the filename date is the " <>
           "UTC date of the run, and it is the only thing pairing a .json with its .md"}
      ]
    else
      _ok -> []
    end
  end

  defp group_disagreements(artifacts) do
    for {gate, {key, companions}} <- @pin_groups,
        {key_value, group} <- artifacts |> Enum.filter(&(&1.gate == gate)) |> group_by(key),
        companion <- companions,
        finding <- disagreement(group, key, key_value, companion),
        do: finding
  end

  defp group_by(artifacts, key) do
    artifacts
    |> Enum.group_by(&Map.get(&1.meta, to_string(key)))
    |> Enum.reject(fn {value, group} -> is_nil(value) or length(group) < 2 end)
  end

  defp disagreement(group, key, key_value, companion) do
    values = group |> Enum.map(&Map.get(&1.meta, to_string(companion))) |> Enum.uniq()

    if length(values) > 1 do
      paths = group |> Enum.map_join(", ", & &1.path)

      [
        {paths,
         "share `meta.#{key}` #{inspect(key_value)} but disagree on `meta.#{companion}` — " <>
           "the same corpus measured under a different configuration is not a like-for-like " <>
           "comparison, however it is quoted"}
      ]
    else
      []
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
