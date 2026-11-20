#!/usr/bin/env bash
# claude-headless.sh — the ONE way anything in this repo spawns a headless `claude`.
#
# WHAT IT IS: a transparent wrapper. It removes the environment variables that decide
# WHO PAYS for the run and WHERE the request goes, then execs the real CLI with your
# argv untouched. stdin, stdout, stderr and the exit code pass straight through, so a
# caller that pipes a prompt in and reads the exit code out sees exactly what it saw
# before. It adds no flags, reorders nothing, and prints nothing of its own.
#
# Use it exactly where you would have typed the binary:
#     bin/claude-headless.sh -p "$PROMPT" --model sonnet --max-turns 8
#     printf '%s' "$INPUT" | bin/claude-headless.sh --print --tools '' --output-format json
#
# THE INCIDENT IT EXISTS FOR (2026-09-07). A headless review run died with:
#
#     API Error: 400 You have reached your specified API usage limits.
#     You will regain access on 2026-10-01
#
# Read that sentence the way it arrives at 1am. It names a usage limit and a reset
# date, so it reads like a plan problem, a quota problem, a rate limit — anything but
# an AUTH problem. It was read past four times. The cause was auth the whole time:
# ANTHROPIC_API_KEY was exported in the shell, so every headless spawn this repo made
# authenticated as that metered API key instead of the claude.ai subscription login.
# Cost, roughly USD 300, plus the silent loss of the org's claude.ai connectors on
# every affected run. The CLI does warn — "claude.ai connectors are disabled because
# ANTHROPIC_API_KEY or another auth source is set and takes precedence over your
# claude.ai login" — one line, on stderr, in a log nobody was reading.
#
# WHY A WRAPPER RATHER THAN A SETTING. Configuration cannot fix this. Measured on a
# machine holding both a claude.ai login and an exported key (second-brain finding
# 855075bc): setting "forceLoginMethod": "claudeai" left `claude auth status` reporting
# forcedLoginMethod claudeai and apiKeySource ANTHROPIC_API_KEY, with `claude doctor`'s
# message byte-identical. The environment variable wins. The only fix is to not hand it
# to the child, per invocation.
#
# WHY NOT UNSET IT GLOBALLY IN THE SHELL PROFILE. Around three dozen files here read
# ANTHROPIC_API_KEY on purpose — the knowledge-extraction pipelines, a scheduled harvest
# LaunchAgent, the segment-detect vision passes. Those call the Anthropic API directly
# and SHOULD bill the key. Only the `claude` CLI must never see it. Stripping per
# invocation is what tells the two apart.
#
# WHAT THAT COSTS THE PYTHON PIPELINES, stated accurately (audited 2026-09-07 on
# mac-mini, `git grep -l ANTHROPIC_API_KEY -- '*.py'` = 21 files). This header used to
# claim "each one load_dotenv()s ~/.env.local itself, so a stripped environment is
# refilled from the file". That is FALSE: only 12 of the 21 have a dotenv fallback.
# The other 9 read the variable straight out of the environment, and inside a headless
# session started through this wrapper they see it unset. What actually saves most of
# them is the SECOND name they try — DOE_ANTHROPIC_API_KEY, which this wrapper
# deliberately does not strip (see below) and which ~/.env.local also defines. Sorted:
#
#   dotenv fallback, unaffected (12): the youtube / web / book / code / document
#       knowledge-extract scripts, content-synthesizer, corpus-synthesizer, the two
#       idea-synthesizer scripts, second-brain-orchestrator/scripts/prune_kb.py,
#       segment-detect/church_service_core.py, video-editing/simple_video_edit.py.
#   no dotenv, but falls back to DOE_ANTHROPIC_API_KEY, so still works (3):
#       segment-detect/church_service_segmenter.py,
#       web-knowledge-extract/scripts/extract_email_bodies.py,
#       youtube-knowledge-extract/scripts/synth.py.
#   no dotenv and no second name — these genuinely lose the key inside a headless
#       session (3): bin/check-model-pins.py, which already prints "fallback freshness:
#       SKIPPED (no ANTHROPIC_API_KEY ...)" rather than failing;
#       skills/second-brain-orchestrator/prune_kb.py (the stale root copy — the live
#       one under scripts/ does load dotenv) and skills/_shared/anthropic_models.py,
#       whose _api_key() takes an explicit key from its caller first.
#   name it without reading it from the environment (2):
#       skills/skill-creator/scripts/improve_description.py, docstring only;
#       youtube-knowledge-extract/tests/synthesis_guard_canary.py, which setdefault()s
#       its own placeholder key.
#
# So the honest statement is: three scripts degrade, one of them loudly and by design,
# and none of them is on a cron or a hook path. Anything added later that needs the key
# inside a headless session must load_dotenv() ~/.env.local for itself.
#
# --- THE MEMBERSHIP TEST ---------------------------------------------------------------
# A variable belongs on the strip list when the INSTALLED CLI reads it AND it can name
# an endpoint, carry a credential, or select which account, org, workspace or provider
# pays. Nothing else qualifies — not a model choice, not a feature flag.
#
# --- HOW THE LIST WAS ENUMERATED, and why the first recipe was not enough --------------
# Round 1 enumerated with:
#
#     strings -a "$(readlink -f "$(command -v claude)")" \
#       | grep -oE 'process\.env\.(ANTHROPIC|CLAUDE)[A-Z0-9_]*' | sort -u
#
# THAT COMMAND IS INCOMPLETE, and this file used to present it as the reproduction.
# Measured against claude 2.1.263 on mac-mini, 2026-09-08: 16 of the 51 names round 1
# had already stripped do not appear in its output at all — ANTHROPIC_IDENTITY_TOKEN,
# CLAUDE_CODE_USE_GATEWAY, CLAUDE_CODE_HOST_CREDS_FILE, the whole Foundry and
# Anthropic-on-GCP endpoint groups. They are in the binary; they are simply not read
# through a literal `process.env.NAME`. So a list built only from that regex looks
# complete and silently omits whole families, which is how round 1 shipped a list
# missing every OAuth-endpoint, account-selecting and non-Anthropic-token variable.
#
# The CLI carries THREE better sources, and all three are what this list now comes from:
#
#   1. Its env-accessor module, one lazy getter per variable it reads:
#        LC_ALL=C grep -aoE '\b(ANTHROPIC|CLAUDE|AWS|GOOGLE|GCLOUD|AZURE)[A-Z0-9_]*:\(\)=>' "$CLI" \
#          | sed 's/:()=>//' | sort -u
#      673 names on 2.1.263. This is the closest thing to a declared list of "the CLI
#      reads this".
#   2. Its OWN CATEGORY ARRAYS, which is the part that matters: the binary classifies
#      these variables itself, so the judgement is the CLI's rather than ours.
#        LC_ALL=C grep -aoE '(Qet|Zet|UU|iL|\$U|IRt|va|Ta|wa|ka|co)=(new Set\()?\[[^]]*\]' "$CLI"
#      On 2.1.263 those are, by content:
#        UU   the credential set    — ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN,
#                                     CLAUDE_CODE_OAUTH_TOKEN, AWS_BEARER_TOKEN_BEDROCK,
#                                     ANTHROPIC_FOUNDRY_API_KEY/_AUTH_TOKEN,
#                                     ANTHROPIC_AWS_API_KEY
#        Zet  the token/secret set  — every *_TOKEN, the four *_FILE_DESCRIPTOR forms,
#                                     and the CLAUDE_BG_* auth channel
#        iL   the endpoint set      — every *_BASE_URL the CLI will honour
#        $U   provider selection    — the USE_* switches plus each provider's project,
#                                     resource and workspace id
#        IRt  the SKIP_*_AUTH set
#        Ta   the TLS channel       — client cert, client key, key passphrase,
#                                     NODE_EXTRA_CA_CERTS, NODE_TLS_REJECT_UNAUTHORIZED,
#                                     CLAUDE_CODE_CERT_STORE and the two cert-drop switches
#        wa   HTTP_PROXY, HTTPS_PROXY, NO_PROXY
#   3. The federation config builder, read directly, which is where
#      ANTHROPIC_SERVICE_ACCOUNT_ID and ANTHROPIC_SCOPE surface:
#        LC_ALL=C grep -aoE 'T\("ANTHROPIC_[A-Z0-9_]*"\)' "$CLI" | sort -u
#
# hooks/tests/headless-launcher-canary.sh's layer 4 runs (1) and (2) against the
# installed binary at test time and fails when a name in the CLI's own credential,
# token, endpoint or provider-selection arrays is neither stripped here nor named in
# the KEPT list below. That is the check round 2 asked for: the expectation comes from
# the binary, not from a sibling copy of this list.
#
# --- STRIPPED, and why each one -------------------------------------------------------
#
# Direct Anthropic API auth and endpoint — the incident and its near relatives:
#   ANTHROPIC_API_KEY            the incident: a metered key outranks the claude.ai login
#   ANTHROPIC_AUTH_TOKEN         the same thing wearing an Authorization: Bearer header
#   ANTHROPIC_CUSTOM_HEADERS     free-form headers, so it can carry either of the above
#   ANTHROPIC_BASE_URL           points the CLI at another endpoint entirely (a gateway,
#                                a proxy, an Ollama box) — whoever runs that endpoint
#                                bills the run, and nothing about the output says so
#   _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL  the CLI lists this as ANTHROPIC_BASE_URL's
#                                companion: it tells the CLI to treat that overridden
#                                endpoint as first-party, which is what suppresses the
#                                warning a redirected endpoint would otherwise print
#   ANTHROPIC_UNIX_SOCKET        routes every request over a local socket instead; the
#                                process on the other end sees the traffic and bills it
#   CLAUDE_CODE_RUNNER_MODEL_SOCKET  the same for a runner's model socket (CLI 2.1.327
#                                lists it beside ANTHROPIC_UNIX_SOCKET and sends a
#                                runner-model proof over it): the runner bills the run
#   CLAUDE_CODE_API_BASE_URL     the CLI's own endpoint override, same effect
#   ANTHROPIC_API_URL            not read by this CLI build; stripped because it is the
#   ANTHROPIC_API_HOST           same class and costs nothing if unread
#
# Credentials that arrive by reference rather than by value. These matter MORE than the
# plain key, not less: `exec` hands the child our open file descriptors, and
# CLAUDE_CODE_HOST_AUTH_ENV_VAR names ANOTHER variable to read the credential from, so
# it is a pointer straight past every name on this list:
#   CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR      an API key on an inherited fd
#   CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR  an OAuth token on an inherited fd
#   CLAUDE_CODE_GATEWAY_TOKEN_FILE_DESCRIPTOR  a gateway token on an inherited fd
#   CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR  the fourth of the set — the CLI groups
#                                all four in one array; round 1 stripped three of them
#   CLAUDE_CODE_OAUTH_REFRESH_TOKEN          mints access tokens for another account
#   CLAUDE_CODE_SESSION_ACCESS_TOKEN         a session bearer token
#   CLAUDE_SESSION_INGRESS_TOKEN_FILE        the ingress token, by file
#   CLAUDE_CODE_HOST_AUTH_ENV_VAR            names the variable holding the credential
#   CLAUDE_CODE_HOST_CREDS_FILE              names the file holding it
#   CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST     the switch that turns those two on
#   CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH    travels with that switch in the CLI's own set
#
# THE ONE THAT OUTRANKED THE LOGIN AND WAS KEPT ANYWAY, now stripped:
#   CLAUDE_CODE_OAUTH_TOKEN      Round 1 kept this and pinned the exclusion, on the
#                                reasoning that it "authenticates AS the subscription, so
#                                it bills the account the login bills", and that a CI
#                                runner with no interactive login has no other way in.
#                                Both halves fail. It is a bearer token for WHATEVER
#                                account minted it, and nothing checks that this is the
#                                machine's own account — the CLI itself puts it in the
#                                same credential array as ANTHROPIC_API_KEY. And the
#                                login-less CI runner does not exist on this fleet:
#                                checked 2026-09-08, beelink (the dedicated CI host)
#                                holds ~/.claude/.credentials.json and sets no token, no
#                                tracked file in this repo sets or reads it, and it is
#                                unset in the shell on mac-mini. Keeping it left exactly
#                                one variable that still outranks the login, which is the
#                                whole class this wrapper exists to close.
#                                WHAT WOULD OVERTURN THIS: a fleet machine provisioned
#                                headless-only, with no ~/.claude/.credentials.json. On
#                                such a box a headless run would fail with "Not logged in"
#                                — loudly, and in the safe direction — and the right fix
#                                is then a documented per-caller re-export, not putting
#                                the blanket exclusion back.
#   CLAUDE_CODE_SESSIONS_OAUTH_TOKEN  new in CLI 2.1.311, listed right after
#                                CLAUDE_CODE_OAUTH_TOKEN in the CLI's own credential arrays:
#                                the same kind of bearer token, stripped for the same reason.
#
# Which account, org, workspace or identity is billed:
#   ANTHROPIC_ORGANIZATION_ID    picks the org
#   ANTHROPIC_WORKSPACE_ID       picks the workspace, which is a billing bucket
#   ANTHROPIC_PROFILE            picks a stored auth profile
#   ANTHROPIC_FEDERATION_RULE_ID selects a federation rule, so a different identity
#   ANTHROPIC_SERVICE_ACCOUNT_ID the federated service account itself — read by the same
#   ANTHROPIC_SCOPE              config builder as the rule id, and missed in round 1
#   ANTHROPIC_IDENTITY_TOKEN     the OIDC federation credential itself, and the file
#   ANTHROPIC_IDENTITY_TOKEN_FILE  form of it
#   CLAUDE_CODE_ACCOUNT_UUID     the CLI reads these three together and, when all are
#   CLAUDE_CODE_USER_EMAIL       present, uses them as the acting identity; the org uuid
#   CLAUDE_CODE_ORGANIZATION_UUID  is also sent as the X-Organization-Uuid header, so it
#                                selects the billed org directly
#   CLAUDE_CODE_ACCOUNT_TAGGED_ID  the tagged form of the account id
#
# The OAuth channel: where the login goes and who it is performed as. Round 1 missed all
# six. Redirecting the OAuth endpoint is the same class of move as redirecting the API
# endpoint — it decides which service issues the credential the run then spends:
#   CLAUDE_CODE_CUSTOM_OAUTH_URL   replaces the OAuth endpoint outright
#   CLAUDE_LOCAL_OAUTH_API_BASE    the local/dev OAuth endpoints, same effect
#   CLAUDE_LOCAL_OAUTH_APPS_BASE
#   CLAUDE_LOCAL_OAUTH_CONSOLE_BASE
#   CLAUDE_CODE_OAUTH_CLIENT_ID    which OAuth client the login is performed as
#   CLAUDE_CODE_OAUTH_SCOPES       what that login is granted
#   CLAUDE_CODE_OAUTH_401_WAIT_MS  how long a 401 on CLAUDE_CODE_OAUTH_TOKEN waits; the CLI
#                                  drops it together with that token, and nothing else reads
#                                  it, so stripping it with the token costs nothing
#
# The TLS channel, which is what decides whether any of the above can be MITM'd. The CLI
# groups these itself:
#   CLAUDE_CODE_CLIENT_CERT         an mTLS client identity: a credential, by any reading
#   CLAUDE_CODE_CLIENT_KEY          its private key
#   CLAUDE_CODE_CLIENT_KEY_PASSPHRASE
#   NODE_EXTRA_CA_CERTS             adds a trust anchor, so an interceptor's certificate
#                                   is accepted and the endpoint can be silently replaced
#   CLAUDE_CODE_CERT_STORE          selects the trust store outright — the same move, and
#                                   the name layer 4 found that this file's own reasoning
#                                   had missed, which is the argument for having layer 4
#   NODE_TLS_REJECT_UNAUTHORIZED    turns certificate verification off entirely
#   CLAUDE_CODE_DISABLE_LOOPED_CROSS_CERT_DROP, CLAUDE_CODE_DISABLE_SELF_NAMED_CERT_DROP
#                                   added to the same group by CLI 2.1.316: each switches
#                                   off a step that discards a suspect certificate, so
#                                   either one widens what the channel trusts
#
# Other Anthropic-service credentials and endpoints the CLI honours. None of them bill
# the model run, but each is a credential this repo never sets on purpose, and handing a
# child a token it did not ask for is the shape of the original incident:
#   CLAUDE_CODE_ARTIFACTS_API_TOKEN   CLAUDE_CODE_ARTIFACTS_API_BASE_URL
#   CLAUDE_CODE_ARTIFACT_ASSET_BASE_URL   CLAUDE_CODE_ARTIFACT_LIVE_BASE_URL
#   CLAUDE_CODE_ARTIFACT_SYNC_BASE_URL    CLAUDE_CODE_ARTIFACT_VIEWER_BASE_URL
#   CLAUDE_CODE_MEMORY_API_TOKEN      CLAUDE_CODE_MEMORY_API_BASE_URL
#   CLAUDE_BRIDGE_OAUTH_TOKEN         CLAUDE_BRIDGE_BASE_URL
#   CLAUDE_BRIDGE_SESSION_INGRESS_URL
#   CLAUDE_CODE_HFI_BEARER_TOKEN      CLAUDE_CODE_SLACK_TAG_TOKEN
#   CLAUDE_CODE_MCP_SERVE_AUTH_TOKEN  AGENT_PROXY_AUTH_TOKEN
#   CLAUDE_TRUSTED_DEVICE_TOKEN       vouches for the device, so it is an auth factor
#
# The background/rendezvous auth channel. The CLI lists these in the SAME secret array as
# the OAuth token. They are set by a parent session for the children IT spawns; a child
# started through this wrapper is not one of those, so inheriting the parent's rendezvous
# credentials joins it to a socket that is not its own:
#   CLAUDE_BG_AUTH_SNAPSHOT_PATH   a snapshot of the parent's auth, by path
#   CLAUDE_BG_SOCKET_TOKENS_PATH   CLAUDE_BG_RV_AUTH
#   CLAUDE_BG_PTY_AUTH             CLAUDE_BG_CLAIM_AUTH
#
# Provider switches. Turning one on moves the whole run onto someone else's bill, and
# `claude --help` names three of these families under --bare. The SKIP_*_AUTH pairs
# travel with their switch and are only meaningful once it has flipped:
#   CLAUDE_CODE_USE_BEDROCK                  AWS pays
#   CLAUDE_CODE_USE_VERTEX                   GCP pays
#   CLAUDE_CODE_USE_FOUNDRY                  Azure AI Foundry pays
#   CLAUDE_CODE_USE_MANTLE                   the Mantle-fronted Bedrock path
#   CLAUDE_CODE_USE_GATEWAY                  an enterprise gateway pays and sees the traffic
#   CLAUDE_CODE_USE_ANTHROPIC_AWS            first-party Anthropic-on-AWS marketplace
#   CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD   first-party Anthropic-on-GCP marketplace
#   CLAUDE_CODE_SKIP_BEDROCK_AUTH   CLAUDE_CODE_SKIP_VERTEX_AUTH
#   CLAUDE_CODE_SKIP_FOUNDRY_AUTH   CLAUDE_CODE_SKIP_MANTLE_AUTH
#   CLAUDE_CODE_SKIP_ANTHROPIC_AWS_AUTH      CLAUDE_CODE_SKIP_ANTHROPIC_GOOGLE_CLOUD_AUTH
#
# Each provider's endpoint, credential and billing target, so a switch flipped from a
# settings.json `env` block rather than from the environment still cannot pick up one:
#   ANTHROPIC_BEDROCK_BASE_URL   ANTHROPIC_BEDROCK_MANTLE_BASE_URL
#   ANTHROPIC_VERTEX_BASE_URL    ANTHROPIC_VERTEX_PROJECT_ID
#   ANTHROPIC_FOUNDRY_BASE_URL   ANTHROPIC_FOUNDRY_RESOURCE
#   ANTHROPIC_FOUNDRY_API_KEY    ANTHROPIC_FOUNDRY_AUTH_TOKEN
#   ANTHROPIC_AWS_BASE_URL       ANTHROPIC_AWS_API_KEY    ANTHROPIC_AWS_WORKSPACE_ID
#   ANTHROPIC_GOOGLE_CLOUD_BASE_URL          ANTHROPIC_GOOGLE_CLOUD_PROJECT
#   ANTHROPIC_GOOGLE_CLOUD_LOCATION          ANTHROPIC_GOOGLE_CLOUD_WORKSPACE_ID
#   AWS_BEARER_TOKEN_BEDROCK     Bedrock API-key auth: a credential, billed to AWS
#
# --- CONSIDERED AND DELIBERATELY LEFT -------------------------------------------------
# Named here so the list above is auditable rather than arbitrary. Each of these was
# looked at and kept for a reason, not missed. Every one is pinned in the canary's
# EXPECTED_KEPT, so an exclusion is falsifiable in the same run as an inclusion.
#
#   HTTP_PROXY, HTTPS_PROXY, NO_PROXY
#                            RAISED IN REVIEW as an unguarded channel, and this is the
#                            deliberate answer. A proxy is transport, not auth: the
#                            request still carries our credential to Anthropic, and the
#                            proxy bills nobody. What made the objection real was the
#                            COMBINATION — a proxy that can also present its own
#                            certificate can read and redirect the channel, and that
#                            capability lives in the TLS-channel variables
#                            (NODE_EXTRA_CA_CERTS, NODE_TLS_REJECT_UNAUTHORIZED,
#                            CLAUDE_CODE_CERT_STORE, the cert-drop switches), which ARE
#                            stripped above. With
#                            verification restored to the system trust store a proxy can
#                            only CONNECT-tunnel the session, not open it. Stripping the
#                            proxy as well would break every machine that needs one to
#                            reach the internet at all, for a door the TLS strips already
#                            close. WHAT WOULD OVERTURN THIS: a fleet machine that must
#                            trust a private CA to work — there, the NODE_EXTRA_CA_CERTS
#                            strip fails loudly with a certificate error, and the fix is a
#                            documented per-caller re-export rather than dropping it.
#   CLAUDE_SECURESTORAGE_CONFIG_DIR  names where the CLI's own credential store lives, so
#                            stripping it on a machine that sets it would take the LOGIN
#                            with it and fix nothing about billing — the same shape as
#                            CLAUDE_CONFIG_DIR below.
#   CLOUD_ML_REGION          the CLI lists it with the Vertex provider switches, but it
#                            names a REGION, not an account, and it is unnamespaced —
#                            gcloud and the Vertex SDKs a headless session shells out to
#                            read it too. Its Anthropic-namespaced twin
#                            ANTHROPIC_GOOGLE_CLOUD_LOCATION IS stripped, because nothing
#                            else reads that one and stripping it is free. The asymmetry
#                            is the blast radius, not the class.
#   AWS_*, GOOGLE_*, AZURE_* the general cloud credential chains. The CLI bundles the AWS,
#                            Google and Azure SDKs, so it names dozens of these, but it
#                            can only reach them once a provider switch is on — and every
#                            switch is stripped above. Meanwhile a headless session shells
#                            out to aws, gcloud and gh, which need them. Stripping the
#                            chain would break real work to close a door already locked.
#                            AWS_BEARER_TOKEN_BEDROCK is the one exception: Bedrock-only,
#                            read by nothing else here.
#   CLAUDE_CONFIG_DIR        select an entire configuration home — settings, plugins, MCP
#   ANTHROPIC_CONFIG_DIR     servers, hooks — not a credential. Stripping them would point
#                            a headless run at a config the machine does not use, and
#                            plugins/agent-git-grant/hooks.ts reads CLAUDE_CONFIG_DIR on
#                            purpose. The residual risk is real but hypothetical: a config
#                            dir holding a DIFFERENT Anthropic login would change who pays.
#                            Revisit if any fleet machine ever sets one.
#   CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS, CLAUDE_CODE_DISABLE_LEGACY_MODEL_REMAP
#                            CLI 2.1.327 puts them in an array with credential names, but
#                            they only switch features off (betas, retired-model remapping);
#                            neither names an account, endpoint or credential, and a caller
#                            that sets one means its run to behave that way.
#   ANTHROPIC_BEDROCK_SERVICE_TIER, ANTHROPIC_BEDROCK_REGION_PREFIX,
#   ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION  shape a Bedrock request; they cannot select an
#                            account, and Bedrock is off because its switch is stripped.
#   DOE_ANTHROPIC_API_KEY    the CLI does not read it, so it cannot redirect a `claude`
#                            run. Scripts a headless session shells out to DO read it —
#                            it is the fallback that keeps four of the no-dotenv python
#                            readers above working — so stripping it would break them for
#                            no gain.
#   ANTHROPIC_MODEL          chooses WHICH model, never which account pays, and callers
#   ANTHROPIC_SMALL_FAST_MODEL   set it on purpose (validate_books_haiku.sh, the
#   ANTHROPIC_DEFAULT_*_MODEL    second-brain sourcers). Stripping would change results.
#   CLAUDECODE               marks "inside a Claude Code session". It changes nesting
#                            behaviour, not billing, and every shell caller here already
#                            spawns fine with it set. The two skill-creator python
#                            callers drop it in their own env for their own reason.
#   CLAUDE_MEMORY, CLAUDE_MEMORY_CAPTURE, CLAUDE_CODE_ENABLE_FUNCTION_HOOKS,
#   DRIP_GATE_*, LOOPCTL_*   callers set these deliberately on the child. Not auth.
#
# Enforced by hooks/tests/headless-launcher-canary.sh, which reads back what the CHILD
# was handed for every name above, fails if any tracked file invokes the CLI directly
# instead of coming through here, and re-derives the expectation from the INSTALLED
# BINARY so a name both this file and the canary forgot cannot stay green.

# A session launched through shell/kimi.sh pins every model slot to a Kimi id and sets
# CLAUDE_HEADLESS_DROP_MODEL_PINS. This launcher strips the Kimi endpoint below, so a hook's
# `--model sonnet` would resolve to kimi-k3 and reach api.anthropic.com as an unknown model.
# The pins belong to the stripped endpoint, so they go with it — and so does the declared
# 1M context window, which is true of kimi-k3 and false of the claude model the child
# resolves to. Indented on purpose: the canary's strip list is the unconditional `^unset`
# lines only.
if [ -n "${CLAUDE_HEADLESS_DROP_MODEL_PINS:-}" ]; then
    unset ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL
    unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
    unset CLAUDE_CODE_MAX_CONTEXT_TOKENS
    # shell/local.sh turns tool search off for the local model (#1029); a Claude child keeps
    # Claude Code's default, or it declares every MCP schema on every request.
    unset ENABLE_TOOL_SEARCH
    unset CLAUDE_HEADLESS_DROP_MODEL_PINS
fi

# `unset` on a variable that was never set is a silent no-op, so this is unconditional.

# Direct Anthropic API auth and endpoint.
unset ANTHROPIC_API_KEY
unset ANTHROPIC_AUTH_TOKEN
unset ANTHROPIC_CUSTOM_HEADERS
unset ANTHROPIC_BASE_URL
unset _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL
unset ANTHROPIC_UNIX_SOCKET
unset CLAUDE_CODE_RUNNER_MODEL_SOCKET
unset CLAUDE_CODE_API_BASE_URL
unset ANTHROPIC_API_URL
unset ANTHROPIC_API_HOST

# Credentials passed by reference: an inherited fd, a named file, or another variable.
unset CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR
unset CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR
unset CLAUDE_CODE_GATEWAY_TOKEN_FILE_DESCRIPTOR
unset CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR
unset CLAUDE_CODE_OAUTH_REFRESH_TOKEN
unset CLAUDE_CODE_SESSION_ACCESS_TOKEN
unset CLAUDE_SESSION_INGRESS_TOKEN_FILE
unset CLAUDE_CODE_HOST_AUTH_ENV_VAR
unset CLAUDE_CODE_HOST_CREDS_FILE
unset CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST
unset CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH

# The subscription bearer token. It outranks the interactive login exactly as the API key
# does, and the fleet has no login-less box that needs it. See the header.
unset CLAUDE_CODE_OAUTH_TOKEN
unset CLAUDE_CODE_SESSIONS_OAUTH_TOKEN

# Which account, org, workspace or identity is billed.
unset ANTHROPIC_ORGANIZATION_ID
unset ANTHROPIC_WORKSPACE_ID
unset ANTHROPIC_PROFILE
unset ANTHROPIC_FEDERATION_RULE_ID
unset ANTHROPIC_SERVICE_ACCOUNT_ID
unset ANTHROPIC_SCOPE
unset ANTHROPIC_IDENTITY_TOKEN
unset ANTHROPIC_IDENTITY_TOKEN_FILE
unset CLAUDE_CODE_ACCOUNT_UUID
unset CLAUDE_CODE_ACCOUNT_TAGGED_ID
unset CLAUDE_CODE_ORGANIZATION_UUID
unset CLAUDE_CODE_USER_EMAIL

# The OAuth channel: which service issues the credential, and who it is issued to.
unset CLAUDE_CODE_CUSTOM_OAUTH_URL
unset CLAUDE_LOCAL_OAUTH_API_BASE
unset CLAUDE_LOCAL_OAUTH_APPS_BASE
unset CLAUDE_LOCAL_OAUTH_CONSOLE_BASE
unset CLAUDE_CODE_OAUTH_CLIENT_ID
unset CLAUDE_CODE_OAUTH_SCOPES
unset CLAUDE_CODE_OAUTH_401_WAIT_MS

# The TLS channel: an mTLS client identity, and the switches that let an interceptor
# be trusted. Stripping these is what makes keeping HTTP(S)_PROXY safe.
unset CLAUDE_CODE_CLIENT_CERT
unset CLAUDE_CODE_CLIENT_KEY
unset CLAUDE_CODE_CLIENT_KEY_PASSPHRASE
unset NODE_EXTRA_CA_CERTS
unset CLAUDE_CODE_CERT_STORE
unset NODE_TLS_REJECT_UNAUTHORIZED
unset CLAUDE_CODE_DISABLE_LOOPED_CROSS_CERT_DROP
unset CLAUDE_CODE_DISABLE_SELF_NAMED_CERT_DROP

# Other Anthropic-service credentials and endpoints the CLI honours.
unset CLAUDE_CODE_ARTIFACTS_API_TOKEN
unset CLAUDE_CODE_ARTIFACTS_API_BASE_URL
unset CLAUDE_CODE_ARTIFACT_ASSET_BASE_URL
unset CLAUDE_CODE_ARTIFACT_LIVE_BASE_URL
unset CLAUDE_CODE_ARTIFACT_SYNC_BASE_URL
unset CLAUDE_CODE_ARTIFACT_VIEWER_BASE_URL
unset CLAUDE_CODE_MEMORY_API_TOKEN
unset CLAUDE_CODE_MEMORY_API_BASE_URL
unset CLAUDE_BRIDGE_OAUTH_TOKEN
unset CLAUDE_BRIDGE_BASE_URL
unset CLAUDE_BRIDGE_SESSION_INGRESS_URL
unset CLAUDE_CODE_HFI_BEARER_TOKEN
unset CLAUDE_CODE_SLACK_TAG_TOKEN
unset CLAUDE_CODE_MCP_SERVE_AUTH_TOKEN
unset AGENT_PROXY_AUTH_TOKEN
unset CLAUDE_TRUSTED_DEVICE_TOKEN

# The background/rendezvous auth channel — the parent's, never this child's.
unset CLAUDE_BG_AUTH_SNAPSHOT_PATH
unset CLAUDE_BG_SOCKET_TOKENS_PATH
unset CLAUDE_BG_RV_AUTH
unset CLAUDE_BG_PTY_AUTH
unset CLAUDE_BG_CLAIM_AUTH

# Provider switches, and the auth skips that travel with them.
unset CLAUDE_CODE_USE_BEDROCK
unset CLAUDE_CODE_USE_VERTEX
unset CLAUDE_CODE_USE_FOUNDRY
unset CLAUDE_CODE_USE_MANTLE
unset CLAUDE_CODE_USE_GATEWAY
unset CLAUDE_CODE_USE_ANTHROPIC_AWS
unset CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD
unset CLAUDE_CODE_SKIP_BEDROCK_AUTH
unset CLAUDE_CODE_SKIP_VERTEX_AUTH
unset CLAUDE_CODE_SKIP_FOUNDRY_AUTH
unset CLAUDE_CODE_SKIP_MANTLE_AUTH
unset CLAUDE_CODE_SKIP_ANTHROPIC_AWS_AUTH
unset CLAUDE_CODE_SKIP_ANTHROPIC_GOOGLE_CLOUD_AUTH

# Each provider's endpoint, credential and billing target.
unset ANTHROPIC_BEDROCK_BASE_URL
unset ANTHROPIC_BEDROCK_MANTLE_BASE_URL
unset ANTHROPIC_VERTEX_BASE_URL
unset ANTHROPIC_VERTEX_PROJECT_ID
unset ANTHROPIC_FOUNDRY_BASE_URL
unset ANTHROPIC_FOUNDRY_RESOURCE
unset ANTHROPIC_FOUNDRY_API_KEY
unset ANTHROPIC_FOUNDRY_AUTH_TOKEN
unset ANTHROPIC_AWS_BASE_URL
unset ANTHROPIC_AWS_API_KEY
unset ANTHROPIC_AWS_WORKSPACE_ID
unset ANTHROPIC_GOOGLE_CLOUD_BASE_URL
unset ANTHROPIC_GOOGLE_CLOUD_PROJECT
unset ANTHROPIC_GOOGLE_CLOUD_LOCATION
unset ANTHROPIC_GOOGLE_CLOUD_WORKSPACE_ID
unset AWS_BEARER_TOKEN_BEDROCK

# Which binary: `claude` on PATH, else the installer's ~/.local/bin/claude, which a
# non-interactive shell (cron, ssh, a hook) may not have on PATH. The fallback only finds
# the CLI; it is a belt, not the mechanism. When neither resolves, fall through to the bare name
# and let exec fail with the familiar 127, which is what the callers saw before.
BIN=claude
command -v claude >/dev/null 2>&1 || { [ -x "$HOME/.local/bin/claude" ] && BIN="$HOME/.local/bin/claude"; }

# exec, not a call: the wrapper leaves no process behind, so signals, the exit code and
# all three streams belong to the CLI exactly as they did before this file existed.
# `${@+"$@"}` rather than "$@" because bash 3.2 — which macOS ships and which
# bin/run-canaries.sh deliberately runs the suite under — errors on "$@" with no
# arguments when nounset is in force in a caller's shell.
exec "$BIN" ${@+"$@"}
