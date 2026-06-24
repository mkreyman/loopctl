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
unless System.get_env("SCALE_TESTS") do
  ExUnit.configure(exclude: [:scale])
end

# Nightly scale tests (TC-27.1.5) seed at PROD_ARTICLE_FLOOR and assert the
# HNSW planner path. They are excluded unless SCALE_NIGHTLY=true is set,
# even when SCALE_TESTS=true (they take several minutes).
unless System.get_env("SCALE_NIGHTLY") do
  ExUnit.configure(exclude: [:scale_nightly])
end
