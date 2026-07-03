defmodule LoopctlWeb.Helpers.ProjectId do
  @moduledoc """
  Validates a client-supplied `project_id` param at the API boundary.

  `project_id` is a `:binary_id` (UUID) column. Threading a raw non-UUID value
  straight into `where a.project_id == ^project_id` makes `Ecto.UUID.dump/1`
  fail, which raises `Ecto.Query.CastError` — an unhandled 500. Every knowledge
  read endpoint that filters by `project_id` (path or query param) calls
  `validate/1` FIRST so a malformed value returns a clean 422 (via
  `LoopctlWeb.FallbackController`) instead of crashing.

  Contract:

    - `nil` / `""` (absent) -> `:ok` (tenant-wide listing stays available)
    - a canonical 36-char dashed UUID -> `:ok`
    - a malformed STRING (non-UUID, wrong length) ->
      `{:error, :unprocessable_entity, message}` (the real 500 vector)
    - a non-string value (e.g. `?project_id[]=x` decodes to a list) -> `:ok`;
      controllers already neutralize these to "no filter" via `string_param/1`,
      and the context filters guard the cast, so they never reach a query as a
      value that could raise. Rejecting them here would needlessly break clients
      that send array-style params.

  The canonical 36-char form is required on purpose: `Ecto.UUID.cast/1` also
  accepts a raw 16-byte binary, so a 16-char junk segment would otherwise coerce
  into a bogus-but-valid UUID and silently narrow (or leak nothing from) a query
  instead of being rejected.
  """

  @error_message "Invalid project_id: must be a valid UUID"

  @doc """
  Validates a `project_id` param value.

  Returns `:ok` for an absent (`nil`/`""`) or valid UUID value, or
  `{:error, :unprocessable_entity, message}` — the shape
  `LoopctlWeb.FallbackController` renders as a 422 — for a malformed value.
  """
  @spec validate(term()) :: :ok | {:error, :unprocessable_entity, String.t()}
  def validate(value) when value in [nil, ""], do: :ok

  def validate(value) when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :unprocessable_entity, @error_message}
    end
  end

  # Any other STRING is a malformed UUID (wrong length / non-hex) — the actual
  # Ecto.Query.CastError vector. Reject it with a 422.
  def validate(value) when is_binary(value),
    do: {:error, :unprocessable_entity, @error_message}

  # Non-string values (list/map from `?project_id[]=x`) are tolerated as "absent":
  # controllers nil them via string_param/1 and the context filters guard the cast.
  def validate(_value), do: :ok
end
