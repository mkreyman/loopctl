defmodule Loopctl.LoggerJsonAllowlistTest do
  @moduledoc """
  Issue #815: production logs are JSON through `LoggerJSON.Formatters.Basic`, which emits
  ONLY the metadata keys it is configured with. A key that is set but not listed is dropped
  silently, which is how the runner correlation ids never reached production.

  `config/test.exs` replaces the formatter, so this reads the PRODUCTION configuration from
  `config/config.exs` (with `prod.exs` layered on) and formats a real event with it.
  """

  use ExUnit.Case, async: true

  @runner_keys [
    :runner_id,
    :runner_name,
    :story_id,
    :dispatch_id,
    :run_id,
    :claim_epoch,
    :node,
    :machine
  ]

  defp prod_formatter do
    config = Config.Reader.read!("config/config.exs", env: :prod, target: :host)

    config
    |> Keyword.fetch!(:logger)
    |> Keyword.fetch!(:default_handler)
    |> Keyword.fetch!(:formatter)
  end

  test "the production JSON line carries every runner correlation key that is set" do
    {formatter, opts} = prod_formatter()

    meta =
      Map.new(@runner_keys, &{&1, "value-of-#{&1}"})
      |> Map.put(:time, System.os_time(:microsecond))

    line =
      %{level: :info, msg: {:string, "runner channel closed"}, meta: meta}
      |> formatter.format(opts)
      |> IO.iodata_to_binary()
      |> Jason.decode!()

    for key <- @runner_keys do
      assert get_in(line, ["metadata", Atom.to_string(key)]) == "value-of-#{key}",
             "#{key} was dropped from the production log line: #{inspect(line)}"
    end
  end
end
