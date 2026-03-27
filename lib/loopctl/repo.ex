defmodule Loopctl.Repo do
  use Ecto.Repo,
    otp_app: :loopctl,
    adapter: Ecto.Adapters.Postgres
end
