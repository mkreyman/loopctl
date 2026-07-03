defmodule LoopctlWeb.Plugs.CastErrorHandler do
  @moduledoc """
  Implements `Plug.Exception` for Ecto cast/change errors so a malformed
  client-supplied value maps to a clean 4xx instead of a raw 500.

  Two distinct failure modes exist, at different points in the request:

    * **Query-time** — an invalid UUID threaded into a `where … == ^value`
      (or a `get_by(id: value)`) against a `:binary_id` column raises
      `Ecto.CastError` / `Ecto.Query.CastError` while *building* the query.
      These map to 404 (the resource that id could name cannot exist).

    * **Insert/update-time** — a value set DIRECTLY on a struct field
      (outside `cast/3`, e.g. `%Skill{project_id: params.project_id}`) is only
      validated when Ecto *dumps* it on `insert`/`update`; a malformed value
      raises `Ecto.ChangeError` at that point. `CastError` handling does NOT
      cover this, so without the impl below it is an unhandled 500. It maps to
      400 (the client sent an unusable parameter).

  These are a defense-in-depth backstop. Endpoints still validate the specific
  `project_id` / `scope_id` params at the boundary (clean 422 + a
  no-partial-write guarantee); this net only exists so a future
  struct-set-uncast value can never surface as a 500.
  """
end

defimpl Plug.Exception, for: Ecto.CastError do
  def status(_exception), do: 404
  def actions(_exception), do: []
end

defimpl Plug.Exception, for: Ecto.Query.CastError do
  def status(_exception), do: 404
  def actions(_exception), do: []
end

defimpl Plug.Exception, for: Ecto.ChangeError do
  # An insert/update-time dump failure on a malformed value is a client-input
  # problem (a bad parameter), so 400 rather than a raw 500.
  def status(_exception), do: 400
  def actions(_exception), do: []
end
