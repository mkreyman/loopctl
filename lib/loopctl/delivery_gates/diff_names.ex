defmodule Loopctl.DeliveryGates.DiffNames do
  @moduledoc """
  Builds Gate B's `:merge` file list from the real diff. Pure: it parses the bytes a caller
  already has and runs nothing.

  The input is the output of

      git diff --name-status -M -z <base>...<head>

  and nothing else: `-z` so no path is quoted and no filename can forge a delimiter, `-M` so
  a rename is one record naming both paths, and no `-B` or `-C`. Each record is a status
  field followed by its paths, every field terminated by a NUL:

      M\\0lib/a.ex\\0
      R100\\0old/path.ex\\0new/path.ex\\0

  ## What it returns

  `{:ok, %{files: files, renames: renames}}`, the two keys `Loopctl.DeliveryGates.GateB`
  requires at `:merge`, derived from one diff of one range so that every rename's new name is
  in `files`:

  - `A` added, `M` modified, `D` deleted, `T` type-changed — the path goes in `files`. A
    deletion under a guarded path is a change to it.
  - `R<score>` renamed — the NEW path goes in `files` and `{old, new}` in `renames`; Gate B
    matches triggers against both names, so a file moved OUT of a guarded path still counts.
  - `C<score>` copied — the NEW path goes in `files` only. A copy leaves its source unchanged,
    so the source is not a touched path. (`-M` alone does not detect copies; the clause is
    here so a caller that adds `-C` gets a correct answer rather than an error.)

  `files` keeps diff order with duplicates removed. An empty diff is `{:ok, %{files: [],
  renames: []}}`, which Gate B escalates as `:no_files`.

  ## What it refuses

  `{:error, reason}` for anything it cannot read with certainty, because a record misread
  here is a guarded path Gate B never sees:

  - `{:unmerged, path}` (`U`) and `{:unknown_status, path}` (`X`): git itself could not
    classify the change
  - `{:unrecognised_status, status}`: any other status field, including `B` and a `M` with a
    dissimilarity score, which only `-B` produces
  - `{:invalid_score, status}`: an `R`/`C` score that is not three digits up to `100`
  - `{:truncated, status}`: a record missing a path
  - `:unterminated`: bytes after the last NUL, i.e. output cut off mid-field
  - `{:empty_path, status}`: an empty path field
  - `{:invalid_utf8, status}`: a path that is not UTF-8
  - `:not_a_binary`

  Paths are otherwise returned exactly as git printed them; Gate B owns the decision about
  which paths it can trust to match (it escalates a quoted, backslashed or `..` path).

  ## Feeding Gate B

  `merge_input/2` puts a parse into a Gate B input. Pass the `parse/1` result through
  untouched: an `{:ok, _}` sets `files` and `renames`, and an `{:error, reason}` replaces
  both with an unreadable-diff marker Gate B turns into `:human`, naming the reason. There is
  no way to evaluate the merge gate over a diff that did not parse.
  """

  @type parsed :: %{files: [String.t()], renames: [{String.t(), String.t()}]}

  @type error ::
          :not_a_binary
          | :unterminated
          | {:unmerged, String.t()}
          | {:unknown_status, String.t()}
          | {:unrecognised_status, String.t()}
          | {:invalid_score, String.t()}
          | {:truncated, String.t()}
          | {:empty_path, String.t()}
          | {:invalid_utf8, String.t()}

  @single_path ~w(A D M T)

  @doc "Parses `git diff --name-status -M -z` output. See the moduledoc."
  @spec parse(term()) :: {:ok, parsed()} | {:error, error()}
  def parse(output) when is_binary(output) do
    with {:ok, fields} <- fields(output),
         {:ok, records} <- records(fields, []) do
      {:ok, collect(records)}
    end
  end

  def parse(_output), do: {:error, :not_a_binary}

  @doc """
  Puts a `parse/1` result into a Gate B `:merge` input.

  `{:ok, parsed}` sets `:files` and `:renames`. Anything else — an `{:error, _}` or a value
  that is not a parse at all — sets `:files` to `{:error, {:unreadable_diff, reason}}` and
  removes `:renames`, so Gate B escalates to `:human` and no `files` or `renames` the caller
  set beforehand can survive a failed parse.
  """
  @spec merge_input(term(), map()) :: map()
  def merge_input({:ok, %{files: files, renames: renames}}, input)
      when is_list(files) and is_list(renames) and is_map(input) do
    Map.merge(input, %{files: files, renames: renames})
  end

  def merge_input({:error, reason}, input) when is_map(input), do: unreadable(input, reason)
  def merge_input(other, input) when is_map(input), do: unreadable(input, {:not_a_parse, other})

  defp unreadable(input, reason) do
    input
    |> Map.delete(:renames)
    |> Map.put(:files, {:error, {:unreadable_diff, reason}})
  end

  # Every field is NUL-TERMINATED, so a complete output ends in NUL and splits into fields
  # plus one trailing "". Anything after the last NUL is a field that was cut off.
  defp fields(""), do: {:ok, []}

  defp fields(output) do
    parts = :binary.split(output, <<0>>, [:global])

    case List.last(parts) do
      "" -> {:ok, Enum.drop(parts, -1)}
      _partial -> {:error, :unterminated}
    end
  end

  defp records([], acc), do: {:ok, Enum.reverse(acc)}

  defp records(["U", path | _rest], _acc), do: {:error, {:unmerged, printable(path)}}
  defp records(["X", path | _rest], _acc), do: {:error, {:unknown_status, printable(path)}}

  defp records([status | rest], acc) do
    with {:ok, kind, arity} <- status(status),
         {:ok, paths, rest} <- take_paths(rest, arity, status) do
      records(rest, [{kind, paths} | acc])
    end
  end

  defp status(status) when status in @single_path, do: {:ok, :changed, 1}

  defp status(<<letter, score::binary>> = status) when letter in [?R, ?C] do
    kind = if letter == ?R, do: :renamed, else: :copied

    if score?(score),
      do: {:ok, kind, 2},
      else: {:error, {:invalid_score, printable(status)}}
  end

  defp status(status) when status in ["U", "X"], do: {:error, {:truncated, status}}
  defp status(status), do: {:error, {:unrecognised_status, printable(status)}}

  # git prints the similarity index zero-padded to three digits.
  defp score?(<<a, b, c>> = score) when a in ?0..?9 and b in ?0..?9 and c in ?0..?9,
    do: String.to_integer(score) <= 100

  defp score?(_score), do: false

  defp take_paths(fields, arity, status) do
    {paths, rest} = Enum.split(fields, arity)

    cond do
      length(paths) < arity -> {:error, {:truncated, printable(status)}}
      Enum.any?(paths, &(&1 == "")) -> {:error, {:empty_path, printable(status)}}
      not Enum.all?(paths, &String.valid?/1) -> {:error, {:invalid_utf8, printable(status)}}
      true -> {:ok, paths, rest}
    end
  end

  defp collect(records) do
    {files, renames} =
      Enum.reduce(records, {[], []}, fn
        {:changed, [path]}, {files, renames} -> {[path | files], renames}
        {:renamed, [old, new]}, {files, renames} -> {[new | files], [{old, new} | renames]}
        {:copied, [_source, new]}, {files, renames} -> {[new | files], renames}
      end)

    %{files: files |> Enum.reverse() |> Enum.uniq(), renames: Enum.reverse(renames)}
  end

  # A status field is echoed in an error; never echo bytes that are not text.
  defp printable(field) do
    if String.valid?(field) and String.printable?(field),
      do: field,
      else: inspect(field, binaries: :as_binaries)
  end
end
