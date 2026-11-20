# The sandbox the live run drives (US-52.9). Ids only; the orchestrator key and the GitHub
# token come from the environment the e2e workflow sets from repository secrets.
#
# Set up once through MCP: a :work project for the sandbox in the operator's tenant, an
# intake source for the repository watching `label`, and two fleet runners whose runner.json
# lists the repository (verify@1 runs on a runner other than the implementer's).
%{
  repo: "mkreyman/loopctl-e2e-sandbox",
  project_id: System.get_env("LOOPCTL_E2E_PROJECT_ID", "PROJECT_ID_UNSET"),
  label: "loopctl"
}
