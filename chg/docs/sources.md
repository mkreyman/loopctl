# Research notes behind design.md (2026-10-16)

## Primary source
https://www.anthropic.com/engineering/redesigning-source-control (Scion + Antique). Fetched twice; quotes in design.md section 1.

## Facts verified on the fleet today (read-only)
- Linux boxes (minis, nuc, beelink) root FS is **ext4 on LVM with 0 free in the VG** (`sudo -n vgs`): no reflink, no room for a new LV. Kernel 7.0.0-38. Passwordless sudo works.
- mac-mini root is APFS (clonefile available, `cp -c`).
- Elixir 1.20.4 (HCB's `.tool-versions`). `mix compile.elixir --no-check-cwd` exists **since 1.19.2**: "Elixir stores absolute paths in .beam files, which means that relocating the project root triggers a full build." Source: `~/.asdf/installs/elixir/1.20.4-otp-28/lib/mix/lib/mix/tasks/compile.elixir.ex:77`, check at `lib/mix/compilers/elixir.ex:104`.
- HCB working tree: `_build` 16,036 files / 607 MB, `deps` 13,750 files / 930 MB. 1,616 `*_test.exs` files.
- fleet-holding: pnpm@12.11.2, workspaces `apps/{api,web,worker}`, `packages/{contracts,db,domain,sheets}`, Vitest 5.0.4, Playwright 1.64.0. No turbo/nx.
- Both repos already attest a local gate as a `local-gate` commit status and skip CI suites on an attested PR head (HCB `ci.yml` job `attest`; fleet-holding US-1.48 `scripts/ci-attest.mjs`).
- HCB's `attest` refuses any head **behind its base** (`compareCommitsWithBasehead ... behind_by > 0` → "run everything; to stay attested, merge the base locally"). That rule is the mechanism behind the measured 51% catch-up merges and 64% full CI re-runs.
- HCB deploys on `workflow_run` of CI on master; fleet-holding deploys newest master commit after verify+e2e, coalescing bursts (ci.yml header comment).
- loopctl change threads: `hooks/lib/thread-mode.sh` (claude-config#702): opt-in marker `.loopctl/mode`, `loop/` branch prefix, no PR, GitHub Actions still judged each checkpoint, loopctl GitHub App squashes. loopctl-runner README: runner dispatches `claude -p` sessions; accept path off by default.

## Prior art sources
- Sapling: https://sapling-scm.com/ ; Mononoke README (OSS build "still in development", no config docs, no Thrift APIs, sqlite/mysql/file/S3 backends): https://github.com/facebook/sapling/blob/main/eden/mononoke/README.md
- Scion-vs-Mononoke attribution thread (derived data idea from Mononoke docs 2022): https://zeli.app/story/50094694
- Jujutsu: https://jj-vcs.github.io/jj/latest/ ; concurrency/op-log design: https://github.com/jj-vcs/jj/blob/main/docs/technical/concurrency.md ; op log man page https://man.archlinux.org/man/jj-operation-log.1.en
- Google Piper/CitC: https://research.google/pubs/why-google-stores-billions-of-lines-of-code-in-a-single-repository/ ; TAP presubmit/postsubmit + culprit finding: https://research.google/pubs/pub52465 , speculative postsubmit cycles (107→37 min median detection): https://hackthology.com/pdfs/icst-2025.pdf , SafeRevert: https://hackthology.com/saferevert-when-can-breaking-changes-be-automatically-reverted.html
- Uber SubmitQueue (conflict graph, speculation): https://lethain.com/static/blog/2019/eurosys19uber.pdf ; OSS Go impl, no releases: https://github.com/uber/submitqueue/ ; follow-up "CI at Scale: Lean, Green, and Fast": https://arxiv.org/html/2501.03440v2
- GitHub merge queue (build concurrency 1-100, group sizes, wait time): https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue
- Aviator parallel mode / batching / affected targets: https://docs.aviator.co/mergequeue/concepts/parallel-mode , https://docs.aviator.co/mergequeue/concepts/batching , https://www.aviator.co/blog/merge-queues-for-large-monorepos/ ; Mergify https://docs.mergify.com/merge-queue/ ; Graphite https://graphite.dev/docs/graphite-merge-queue
- gitoxide crate status (merge/cherry-pick/revert/rebase/push "still need plumbing"): https://github.com/GitoxideLabs/gitoxide/blob/main/crate-status.md
- git merge-tree --write-tree (in-memory merge-ort, no worktree): https://git-scm.com/docs/git-merge-tree ; git replay (server-side rebase built for GitLab bare repos): https://git-scm.com/docs/git-replay , https://about.gitlab.com/blog/gitlabs-contributions-to-git-2-44-0/
- Scalar / partial clone: https://git-scm.com/docs/scalar , https://git-scm.com/docs/partial-clone
- Bazel remote cache model: https://bazel.build/remote/caching ; bazel-remote server https://github.com/buchgr/bazel-remote
- Vitest `--changed` / `related`: https://vitest.dev/guide/cli ; module-graph fix for transitive imports https://github.com/vitest-dev/vitest/commit/9c7c0fc9
- pnpm global virtual store: https://pnpm.io/settings#enableglobalvirtualstore
- Elixir relocation recompile PR: https://github.com/elixir-lang/elixir/pull/12462

## KB
3 calls this turn: two `knowledge_search` timed out at 30s, one `knowledge_hybrid_search` returned 503 `db_unavailable`. Retrieval failed; nothing from the KB informs design.md.
