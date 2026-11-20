defmodule Shared do
  @moduledoc "A path dependency: its build lives in the app's build, its source here."
  def rule, do: :shared
end
