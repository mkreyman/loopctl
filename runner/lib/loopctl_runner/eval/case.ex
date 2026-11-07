defmodule LoopctlRunner.Eval.Case do
  @moduledoc """
  One eval case (US-48.10, AC-48.10.1): `eval/<spec>@<version>/<case>.json`.

      {"spec": "triage", "version": 1,
       "description": "optional, for the person reading the case",
       "input": { ...the RunnerDispatch exactly as loopctl would send it... },
       "fixture": {"repo": "fixtures/tiny_app.json", "commit": "<40-hex sha>"},
       "expectations": {
         "schema_valid": true,
         "outcomes_allowed": ["story"],
         "escalation_codes": [],
         "lens_agreement": true,
         "forbidden": ["<regex>"],
         "screens": ["gate_a"],
         "rubric": null}}

  The shape is `@schema`, judged by the runner's own validator (`LoopctlRunner.Contract.
  validate_against/3`), and then what a schema cannot say: the directory names the spec and
  version the file does, the runner holds that template, `input` is a `RunnerDispatch` under the
  vendored contract whose `kind` is the template's, each `forbidden` entry compiles, and the
  expectations that only mean something for one archetype are not set on another
  (`escalation_codes` and `lens_agreement` are a `:judge`'s), and every `screens` entry is a
  screen loopctl replays that spec through (`screen_names/1`). The fixture is resolved through
  `LoopctlRunner.Eval.Fixture.resolve/3`, the guard that keeps a case off every real repository.

  Deterministic expectations come first, by design: `rubric` is text for a person to judge, set
  only where text quality is the point, and the harness never scores it.

  ## Offline responses

  `eval/offline/<spec>@<version>/<case>.json` is what the FAKE CLI (`test/support/bin/claude`)
  does for the case when the harness runs offline (`--cli`), and nothing else: the real CLI never
  reads a `FAKE_*` variable. `mode` (default `stream`), `exit`, `verdict` (the object a triage
  session states through `loop-verdict`), `final_message` (a draft session's last message) and
  `escalate` (what the session runs `loop-escalate` with), and `when_prompt_contains` (`text`, with
  the `verdict` and/or `final_message` the fake states instead when its prompt contains `text` —
  how an offline run tells a proposed template revision from the current one, US-48.13).
  """

  alias LoopctlRunner.{Contract, DispatchShape, Templates}
  alias LoopctlRunner.Eval.Fixture

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["spec", "version", "input", "fixture", "expectations"],
    "properties" => %{
      "spec" => %{"type" => "string", "pattern" => "^[a-z][a-z0-9_]*$", "maxLength" => 64},
      "version" => %{"type" => "integer", "minimum" => 1},
      "description" => %{"type" => "string", "maxLength" => 1000},
      "input" => %{"type" => "object"},
      "fixture" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["repo", "commit"],
        "properties" => %{
          "repo" => %{"type" => "string", "minLength" => 1, "maxLength" => 300},
          "commit" => %{"type" => "string", "pattern" => "^[0-9a-f]{40}$"}
        }
      },
      "expectations" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" =>
          ~w(schema_valid outcomes_allowed escalation_codes lens_agreement forbidden screens rubric),
        "properties" => %{
          "schema_valid" => %{"type" => "boolean"},
          "outcomes_allowed" => %{
            "type" => "array",
            "minItems" => 1,
            "items" => %{"type" => "string", "minLength" => 1}
          },
          "escalation_codes" => %{"type" => "array", "items" => %{"type" => "string"}},
          "lens_agreement" => %{"type" => ["boolean", "null"]},
          "forbidden" => %{"type" => "array", "items" => %{"type" => "string", "minLength" => 1}},
          "screens" => %{"type" => "array", "items" => %{"type" => "string", "minLength" => 1}},
          "rubric" => %{"type" => ["string", "null"], "maxLength" => 500}
        }
      }
    }
  }

  @offline_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "mode" => %{"type" => "string", "pattern" => "^[a-z_]+$"},
      "exit" => %{"type" => "integer", "minimum" => 0},
      "verdict" => %{"type" => "object"},
      "final_message" => %{"type" => "string"},
      "escalate" => %{"type" => "string", "minLength" => 1},
      # What the fake does instead when its PROMPT contains `text`: the one way an offline run can
      # tell two templates apart, which is what scoring a proposed revision needs (US-48.13).
      "when_prompt_contains" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["text"],
        "properties" => %{
          "text" => %{"type" => "string", "minLength" => 1},
          "verdict" => %{"type" => "object"},
          "final_message" => %{"type" => "string"}
        }
      }
    }
  }

  @type t :: %{
          name: String.t(),
          path: String.t(),
          raw: map(),
          template: Templates.t(),
          input: map(),
          fixture_path: String.t(),
          commit: String.t(),
          expectations: map(),
          forbidden: [Regex.t()],
          offline: map()
        }

  @doc "The case-file schema, as the validator reads it."
  @spec schema() :: map()
  def schema, do: @schema

  @doc """
  Every case for `spec_arg` (`triage` or `triage@1`) under `eval_dir`, loaded and checked; the
  first refusal refuses them all, so a run never starts with a case that could reach outside the
  fixtures.
  """
  @spec load_all(String.t(), String.t(), String.t()) :: {:ok, [t()]} | {:error, String.t()}
  def load_all(spec_arg, eval_dir, scratch_dir) do
    with {:ok, dirs} <- spec_dirs(spec_arg, eval_dir),
         {:ok, files} <- case_files(dirs, spec_arg, eval_dir) do
      load_each(files, eval_dir, scratch_dir, [])
    end
  end

  defp case_files(dirs, spec_arg, eval_dir) do
    case Enum.flat_map(dirs, &(&1 |> Path.join("*.json") |> Path.wildcard() |> Enum.sort())) do
      [] -> {:error, "no eval cases for #{spec_arg} under #{eval_dir}"}
      files -> {:ok, files}
    end
  end

  defp load_each([], _eval_dir, _scratch_dir, acc), do: {:ok, Enum.reverse(acc)}

  defp load_each([file | rest], eval_dir, scratch_dir, acc) do
    with {:ok, loaded} <- load(file, eval_dir, scratch_dir),
         do: load_each(rest, eval_dir, scratch_dir, [loaded | acc])
  end

  @spec_arg ~r/\A([a-z][a-z0-9_]{0,63})(?:@([1-9][0-9]{0,8}))?\z/

  defp spec_dirs(spec_arg, eval_dir) do
    case Regex.run(@spec_arg, spec_arg) do
      [_, spec, version] ->
        dir = Path.join(eval_dir, "#{spec}@#{version}")
        if File.dir?(dir), do: {:ok, [dir]}, else: {:error, "no eval set #{dir}"}

      [_, spec] ->
        case eval_dir |> Path.join("#{spec}@*") |> Path.wildcard() |> Enum.filter(&File.dir?/1) do
          [] -> {:error, "no eval set for #{spec} under #{eval_dir}"}
          dirs -> {:ok, Enum.sort(dirs)}
        end

      nil ->
        {:error, "#{inspect(spec_arg)} is not <spec> or <spec>@<version>"}
    end
  end

  @doc "Loads one case file and checks it (see the moduledoc)."
  @spec load(String.t(), String.t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(file, eval_dir, scratch_dir) do
    name = Path.basename(file, ".json")

    with {:ok, raw} <- decode_file(file),
         :ok <- against(@schema, raw, file),
         :ok <- in_its_directory(raw, file) do
      checked(raw, name, file, eval_dir, scratch_dir)
    end
  end

  @doc """
  A case that is not a file: `raw` in the case-file shape, named `name`, checked exactly as
  `load/3` checks a file except for the directory it would live in. `label` is what each refusal
  names in place of a path. The spec tuner's proposed cases are loaded this way
  (`LoopctlRunner.SpecTune`), so a case a session wrote is held to every rule a committed one is —
  the fixture guard included — and never written into `eval/`.
  """
  @spec from_map(map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, String.t()}
  def from_map(raw, name, label, eval_dir, scratch_dir) when is_map(raw) do
    with :ok <- against(@schema, raw, label),
         do: checked(raw, name, label, eval_dir, scratch_dir)
  end

  defp checked(raw, name, file, eval_dir, scratch_dir) do
    with {:ok, template} <- template(raw, file),
         :ok <- dispatch(raw["input"], template, file),
         :ok <- archetype_expectations(raw["expectations"], template, file),
         :ok <- screens(raw["spec"], raw["expectations"]["screens"], file),
         {:ok, forbidden} <- forbidden(raw["expectations"]["forbidden"], file),
         {:ok, fixture_path} <- fixture(raw["fixture"]["repo"], eval_dir, scratch_dir, file),
         {:ok, offline} <- offline(eval_dir, raw, name) do
      {:ok,
       %{
         name: name,
         path: file,
         raw: raw,
         template: template,
         input: raw["input"],
         fixture_path: fixture_path,
         commit: raw["fixture"]["commit"],
         expectations: raw["expectations"],
         forbidden: forbidden,
         offline: offline
       }}
    end
  end

  defp decode_file(file) do
    with {:ok, raw} <- File.read(file),
         {:ok, %{} = map} <- Jason.decode(raw) do
      {:ok, map}
    else
      {:ok, _} -> {:error, "#{file}: not a JSON object"}
      {:error, %Jason.DecodeError{} = error} -> {:error, "#{file}: #{Exception.message(error)}"}
      {:error, reason} -> {:error, "#{file}: #{:file.format_error(reason)}"}
    end
  end

  defp against(schema, value, file) do
    case Contract.validate_against(schema, value, "case") do
      :ok -> :ok
      {:error, errors} -> {:error, "#{file}: " <> Enum.join(errors, "; ")}
    end
  end

  defp in_its_directory(%{"spec" => spec, "version" => version}, file) do
    if Path.basename(Path.dirname(file)) == "#{spec}@#{version}",
      do: :ok,
      else: {:error, "#{file}: a #{spec}@#{version} case must live in eval/#{spec}@#{version}/"}
  end

  defp template(%{"spec" => spec, "version" => version}, file) do
    case Templates.fetch({spec, version}) do
      {:ok, template} -> {:ok, template}
      :error -> {:error, "#{file}: this runner holds no template #{spec}@#{version}"}
    end
  end

  defp dispatch(input, template, file) do
    cond do
      input["kind"] != template.kind ->
        {:error, "#{file}: input.kind #{inspect(input["kind"])} is not #{template.kind}"}

      (errors = dispatch_errors(input)) != [] ->
        {:error, "#{file}: input is not a RunnerDispatch: " <> Enum.join(errors, "; ")}

      true ->
        :ok
    end
  end

  # The schema, then what it cannot say (`DispatchShape`, contract 1.30.0): since `story_id` left
  # the schema's `required`, an input with none passes the schema and is still no dispatch loopctl
  # would send for any kind but `spec_tune`.
  defp dispatch_errors(input) do
    case Contract.validate("RunnerDispatch", input) do
      :ok -> DispatchShape.errors(input)
      {:error, errors} -> errors
    end
  end

  @doc """
  The screens loopctl replays a spec's recorded message through, by the names loopctl's replay
  uses: what a case may expect to trip. `implement` has none — loopctl refuses to replay a
  `session_ended` — so an implement case's `screens` is always `[]`. A clean result is `[]`.
  """
  @spec screen_names(String.t()) :: [String.t()]
  def screen_names("triage"), do: ~w(gate_a gate_b draft_injection draft_dispatchable)
  def screen_names("reply_draft"), do: ~w(injection_detector_draft)
  def screen_names(_spec), do: []

  defp screens(spec, screens, file) do
    case screens -- screen_names(spec) do
      [] ->
        :ok

      unknown ->
        {:error,
         "#{file}: #{Enum.join(unknown, ", ")} is not a screen loopctl replays #{spec} through " <>
           "(#{inspect(screen_names(spec))})"}
    end
  end

  defp archetype_expectations(_expectations, %{archetype: :judge}, _file), do: :ok

  defp archetype_expectations(expectations, template, file) do
    cond do
      expectations["escalation_codes"] != [] ->
        {:error,
         "#{file}: escalation_codes are a :judge's, and #{template.id} is a #{template.archetype}"}

      expectations["lens_agreement"] != nil ->
        {:error,
         "#{file}: lens_agreement is a :judge's, and #{template.id} is a #{template.archetype}"}

      true ->
        :ok
    end
  end

  defp forbidden(patterns, file) do
    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, acc} ->
      case Regex.compile(pattern, "u") do
        {:ok, regex} -> {:cont, {:ok, acc ++ [regex]}}
        {:error, _} -> {:halt, {:error, "#{file}: forbidden #{inspect(pattern)} is not a regex"}}
      end
    end)
  end

  defp fixture(repo, eval_dir, scratch_dir, file) do
    case Fixture.resolve(repo, eval_dir, scratch_dir) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, "#{file}: #{reason}"}
    end
  end

  defp offline(eval_dir, %{"spec" => spec, "version" => version}, name) do
    file = Path.join([eval_dir, "offline", "#{spec}@#{version}", name <> ".json"])

    if File.exists?(file) do
      with {:ok, raw} <- decode_file(file),
           :ok <- against(@offline_schema, raw, file),
           do: {:ok, raw}
    else
      {:ok, %{}}
    end
  end

  @doc """
  The fake CLI's environment for a case run offline, from its offline response. `state_dir` is
  where the fake records what it saw (`FAKE_STATE_DIR`, which it requires).
  """
  @spec fake_env(t(), String.t()) :: %{String.t() => String.t()}
  def fake_env(%{offline: offline}, state_dir) do
    %{"FAKE_STATE_DIR" => state_dir, "FAKE_CLAUDE_MODE" => Map.get(offline, "mode", "stream")}
    |> put_if(offline["exit"], "FAKE_EXIT", &Integer.to_string/1)
    |> put_if(offline["verdict"], "FAKE_VERDICT", &Jason.encode!/1)
    |> put_if(offline["final_message"], "FAKE_RESULT_LINE", &result_line/1)
    |> put_if(offline["escalate"], "FAKE_ESCALATE", & &1)
    |> switched(offline["when_prompt_contains"])
  end

  defp switched(env, nil), do: env

  defp switched(env, switch) do
    env
    |> Map.put("FAKE_SWITCH_TEXT", switch["text"])
    |> put_if(switch["verdict"], "FAKE_SWITCH_VERDICT", &Jason.encode!/1)
    |> put_if(switch["final_message"], "FAKE_SWITCH_RESULT_LINE", &result_line/1)
  end

  defp put_if(env, nil, _name, _fun), do: env
  defp put_if(env, value, name, fun), do: Map.put(env, name, fun.(value))

  # The CLI's final stream-json line, carrying `text` as the session's last message.
  defp result_line(text) do
    Jason.encode!(%{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "num_turns" => 1,
      "result" => text
    })
  end
end
