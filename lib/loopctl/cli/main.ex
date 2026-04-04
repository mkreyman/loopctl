defmodule Loopctl.CLI.Main do
  @moduledoc """
  Escript entry point and top-level command router for the loopctl CLI.

  Parses the first argument as a command group, delegates to the
  appropriate command module, and handles global flags like `--format`.
  """

  alias Loopctl.CLI.Commands

  @commands %{
    "config" => Commands.Config,
    "auth" => Commands.Auth,
    "tenant" => Commands.Tenants,
    "keys" => Commands.Keys,
    "project" => Commands.Projects,
    "import" => Commands.Projects,
    "export" => Commands.Projects,
    "status" => Commands.Status,
    "next" => Commands.Status,
    "blocked" => Commands.Status,
    "agent" => Commands.Agent,
    "contract" => Commands.Agent,
    "claim" => Commands.Agent,
    "start" => Commands.Agent,
    "report" => Commands.Agent,
    "unclaim" => Commands.Agent,
    "verify" => Commands.Orchestrator,
    "reject" => Commands.Orchestrator,
    "pending" => Commands.Orchestrator,
    "state" => Commands.Orchestrator,
    "history" => Commands.Webhooks,
    "audit" => Commands.Webhooks,
    "changes" => Commands.Webhooks,
    "webhook" => Commands.Webhooks,
    "skill" => Commands.Skills,
    "admin" => Commands.Admin,
    "cost-summary" => Commands.Token,
    "token-report" => Commands.Token,
    "anomalies" => Commands.Token
  }

  @doc """
  Escript main entry point. Receives command-line arguments as a list of strings.
  """
  @spec main([String.t()]) :: :ok
  def main(args) do
    {global_opts, rest} = extract_global_opts(args)

    case rest do
      [] ->
        print_usage()

      ["help" | _] ->
        print_usage()

      ["--help" | _] ->
        print_usage()

      [command | sub_args] ->
        dispatch(command, sub_args, global_opts)
    end
  end

  @doc false
  @spec dispatch(String.t(), [String.t()], keyword()) :: :ok
  def dispatch(command, args, global_opts) do
    case Map.get(@commands, command) do
      nil ->
        IO.puts(:stderr, "Unknown command: #{command}")
        IO.puts(:stderr, "Run 'loopctl help' for available commands.")

      module ->
        module.run(command, args, global_opts)
    end
  end

  defp extract_global_opts(args) do
    {parsed, rest} =
      Enum.reduce(args, {[], []}, fn
        "--format", {opts, rest} ->
          {[{:format_next, true} | opts], rest}

        arg, {[{:format_next, true} | opts], rest} ->
          {[{:format, arg} | opts], rest}

        arg, {opts, rest} ->
          {opts, rest ++ [arg]}
      end)

    opts =
      parsed
      |> Enum.reject(fn {k, _} -> k == :format_next end)
      |> Keyword.new()

    {opts, rest}
  end

  defp print_usage do
    IO.puts("""
    loopctl - Agent-native project state store CLI

    Usage: loopctl [--format json|human|csv] <command> [args]

    Commands:
      config    Configuration management (set, get, show)
      auth      Authentication (login, whoami)
      tenant    Tenant management (register, info, update)
      keys      API key management (create, list, revoke, rotate)
      project   Project management (create, list, info, archive)
      import    Import user stories from JSON
      export    Export project to JSON
      status    Progress and status queries
      next      List ready stories
      blocked   List blocked stories
      agent     Agent registration
      contract  Contract a story
      claim     Claim a story
      start     Start implementing
      report    Report done
      unclaim   Release assignment
      verify    Verify a story
      reject    Reject a story
      pending   List pending stories
      state     Orchestrator state management
      history   Story audit history
      audit     Query audit log
      changes   Change feed
      webhook   Webhook management
      skill         Skill management
      admin         Superadmin operations
      cost-summary  Project/epic/agent cost overview
      token-report  Detailed story token usage
      anomalies     Cost anomaly listing

    Global options:
      --format json|human|csv  Output format (default: json)
    """)
  end
end
