ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Loopctl.Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(Loopctl.AdminRepo, :manual)

# Scale tests (US-27.1) are opt-in: they seed large corpora, commit rows
# directly to the DB, and run ANALYZE. They must NEVER run inside the normal
# async sandbox suite — doing so would silently produce n≈0 statistics.
#
# To run scale tests:
#   SCALE_TESTS=true mix test --only scale
#
# Plain `mix test` always excludes :scale.
# ExUnit.configure(exclude: ...) REPLACES the exclude list — it does not merge.
# Both exclusions must be specified in a single call so neither overwrites the other.
#
# To run scale tests:
#   SCALE_TESTS=true mix test --only scale
#
# To run nightly scale tests:
#   SCALE_TESTS=true SCALE_NIGHTLY=true mix test --only scale_nightly
#
# Plain `mix test` always excludes both :scale and :scale_nightly.
scale_excluded = if System.get_env("SCALE_TESTS"), do: [], else: [:scale]
nightly_excluded = if System.get_env("SCALE_NIGHTLY"), do: [], else: [:scale_nightly]
ExUnit.configure(exclude: scale_excluded ++ nightly_excluded)
