# The live run (tagged :live) needs the orchestrator key; without it the suite is the
# harness's unit tests only (AC-52.9.8).
live? = System.get_env("LOOPCTL_E2E_ORCH_KEY") not in [nil, ""]
ExUnit.start(exclude: if(live?, do: [], else: [:live]))
