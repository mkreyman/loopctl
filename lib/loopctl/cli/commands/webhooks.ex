defmodule Loopctl.CLI.Commands.Webhooks do
  @moduledoc """
  CLI commands for webhooks, audit log, and change feed.

  Commands:
  - `loopctl webhook create --url <url> --events <list>`
  - `loopctl webhook list`
  - `loopctl webhook delete <id>`
  - `loopctl webhook test <id>`
  - `loopctl history <story_number>`
  - `loopctl audit --project <project> --since <date>`
  - `loopctl changes --project <project> --since <timestamp>`
  """

  alias Loopctl.CLI.Output

  @doc false
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run(_command, _args, _opts) do
    Output.error("Webhook/audit commands not yet implemented")
  end
end
