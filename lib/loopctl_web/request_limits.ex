defmodule LoopctlWeb.RequestLimits do
  @moduledoc """
  The transport-level request bounds, in ONE place.

  `max_body_bytes/0` is the length `Plug.Parsers` is mounted with in
  `LoopctlWeb.Endpoint`, the message `LoopctlWeb.ErrorJSON` renders when the parser
  refuses a body, and the bound the corpus ingest OpenAPI description publishes
  alongside its item ceiling. Those three read the same number because they used to
  drift: the ingest schema advertised an item ceiling that a `client_embedded` batch
  could not reach, since a batch of vectors is bounded by BYTES long before it is
  bounded by items, and the refusal arrived as an uncoded 413 from the parser — for a
  request the published schema declared valid.

  A cap raise is therefore a one-line change here, and every site that speaks about it
  moves with it.
  """

  @max_body_bytes 2_000_000

  @doc "The maximum request body `Plug.Parsers` will read, in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes
end
