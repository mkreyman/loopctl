defmodule Mix.Tasks.Loopctl.RunnerContract do
  @shortdoc "Writes the runner wire contract to priv/runner_contract/"

  @moduledoc """
  Writes `Loopctl.ApiSpec.RunnerContract` as JSON Schema to
  `priv/runner_contract/v<major>.json`, the file `mkreyman/loopctl-runner` vendors.

      mix loopctl.runner_contract

  Run it after changing any schema in that module. The checked-in file is compared
  against the declarations by `test/loopctl/api_spec/runner_contract_test.exs`, so a
  forgotten run fails the build rather than shipping a contract loopctl does not enforce.
  """

  use Mix.Task

  alias Loopctl.ApiSpec.RunnerContract

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")

    path = RunnerContract.export_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, RunnerContract.encoded_json_schema())
    Mix.shell().info("wrote #{path} (contract #{RunnerContract.version()})")
  end
end
