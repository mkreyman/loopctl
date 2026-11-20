import Config

# The launchd agent's log file carries no timestamp of its own, so every line needs the date
# and an unambiguous zone; the three machines sit in different zones from loopctl's servers.
config :logger, utc_log: true

# runner_id on every daemon line, and a dispatch's identifiers on its lines: the keys loopctl's
# own logs carry, so the two sides of one incident can be joined.
config :logger, :default_formatter,
  format: "$date $time UTC [$level] $metadata$message\n",
  metadata: [:runner_id, :dispatch_id, :story_id, :claim_epoch, :run_id]
