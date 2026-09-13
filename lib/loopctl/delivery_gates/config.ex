defmodule Loopctl.DeliveryGates.Config do
  @moduledoc """
  Loads Gate B's trigger configuration from the application environment. The one I/O step
  in front of the gates, which stay pure.

  `config/runtime.exs` copies two environment variables into
  `config :loopctl, Loopctl.DeliveryGates.Config`, verbatim and unparsed:

  - `:document` — `DELIVERY_GATES_CONFIG`, the trigger JSON document, inline
  - `:sha256` — `DELIVERY_GATES_CONFIG_SHA256`, the hex SHA-256 of those exact bytes

  `triggers/0` returns exactly what `Loopctl.DeliveryGates.Triggers.parse/2` returns for
  that pair, and nothing is special-cased on the way: an unset or empty document is
  `{:error, :missing_config}`, a document without its checksum is
  `{:error, :invalid_checksum_format}`, and a checksum over different bytes is
  `{:error, :checksum_mismatch}`. Hand the result to `Loopctl.DeliveryGates.gate_b/3`
  untouched; every `{:error, _}` there is a `:human` result naming the failure. So a
  deployment that never configured the triggers escalates every delivery-loop change to a
  human — the intended fail-closed state, never an empty trigger set.

  Read at call time rather than cached, so a `fly secrets set` plus restart takes effect
  without a deploy, and a trigger set is never older than the environment it came from.

  ## Why inline, and not a file path

  The document is a map of which paths skip human review, so it must stay out of the public
  source tree — which a path on the release image would not. A secret is also the one store
  the checksum can be pinned beside in the same `fly secrets set`. Size is no reason to
  split it out: Fly documents no per-secret limit, and the binding ceiling is Linux's
  per-string `MAX_ARG_STRLEN` (32 pages, 128 KiB at a 4 KiB page) on the process
  environment, against a document of a few kilobytes per repository.
  """

  alias Loopctl.DeliveryGates.Triggers

  @doc """
  The configured trigger set, verified against its pinned checksum.
  """
  @spec triggers() :: {:ok, Triggers.t()} | {:error, Triggers.error()}
  def triggers do
    :loopctl
    |> Application.get_env(__MODULE__, [])
    |> from_config()
  end

  @doc """
  `triggers/0` over an explicit configuration keyword list, `[document: _, sha256: _]`.
  Anything that is not a keyword list is `{:error, :missing_config}`.
  """
  @spec from_config(term()) :: {:ok, Triggers.t()} | {:error, Triggers.error()}
  def from_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      Triggers.parse(Keyword.get(config, :document), Keyword.get(config, :sha256))
    else
      {:error, :missing_config}
    end
  end

  def from_config(_config), do: {:error, :missing_config}
end
