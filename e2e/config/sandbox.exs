# The sandbox the live run drives (US-52.9). The orchestrator key and the GitHub token come
# from repository secrets, and the project id from the repository variable
# LOOPCTL_E2E_PROJECT_ID; the e2e workflow sets all three in the environment. Without the
# project id the run refuses to start (LoopctlE2e.Run.execute/4) rather than open an issue
# no story lookup can find.
#
# Set up once through MCP: a :work project for the sandbox in the operator's tenant (its id
# goes into the repository variable), an intake source for the repository watching `label`,
# and EVERY live fleet runner's runner.json listing the repository, each with a clone at the
# path it names (runner.json stays chmod 600: the runner refuses to start otherwise).
# verify@1 runs on a runner other than the implementer's, and a runner holds a slot through
# its story's `ci` stage, so with only two listed one busy machine leaves the verifier with
# nowhere to go: on 2026-11-20 the run failed at review_recorded that way.
%{
  repo: "mkreyman/loopctl-e2e-sandbox",
  project_id: System.get_env("LOOPCTL_E2E_PROJECT_ID"),
  label: "loopctl"
}
