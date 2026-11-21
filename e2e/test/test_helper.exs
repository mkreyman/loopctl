# The live run (tagged :live) needs the orchestrator key; without it the suite is the
# harness's unit tests only (AC-52.9.8). The two-session scenario (US-52.20) is :live too and
# also excluded by its own tag, because it takes about 16 minutes and needs
# LOOPCTL_E2E_AGENT_KEY: `mix e2e --only two_sessions_one_repo` runs it (`--only` includes
# what an exclude names).
live? = System.get_env("LOOPCTL_E2E_ORCH_KEY") not in [nil, ""]
exclude = [:two_sessions_one_repo | if(live?, do: [], else: [:live])]
ExUnit.start(exclude: exclude)
