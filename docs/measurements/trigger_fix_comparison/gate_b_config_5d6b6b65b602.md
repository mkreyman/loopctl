Gate B replay — mkreyman/home_care_billing
window: repository start .. corpus head (head 03ad989c711a433812727fdb4bee8d512857fe5d)
changes: 854 (readable 853, unreadable 1, stale-trigger 712)
outcomes: clear 45, prove_effect 56, human 731, size_bound 21, unreadable 1
reason kinds: [hard_bound_changed_lines_exceeded: 272, hard_bound_files_exceeded: 239, human_path: 150, max_changed_lines_exceeded: 272, max_files_exceeded: 239, stale_trigger: 712]

all readable: n=853 cleared=45 (5.3%) scored_clears=45 false_negatives=17 (37.8%) [2025-12-13 .. 2026-09-14]
configuration applied: n=141 cleared=45 (31.9%) scored_clears=45 false_negatives=17 (37.8%) [2026-08-20 .. 2026-09-14]
  ... of those, production files: n=117 cleared=26 (22.2%) scored_clears=26 false_negatives=11 (42.3%) [2026-08-20 .. 2026-09-14]

`clear` is Gate B's own clear plus the size bound, NOT the auto-merge set. Loopctl.Delivery.MergePrecondition additionally requires Gate A, custody, an unmoved head and an open pull request, so `clear` is a strict SUPERSET of what would actually auto-merge. The false-negative rate survives that: everything the merge precondition adds can only REMOVE changes from this set, never add one.

false negatives listed: 17
unscored clears (oracle could not run): 0

Read with these:
  - The oracle over-flags by construction (a HCPCS-shaped literal in a test assertion fires it), so the false-negative rate is an UPPER bound.
  - The oracle is lexical and path-blind, so an arithmetic change that moves claim output without naming any billing vocabulary is invisible to it. A false-negative count of zero is NOT evidence that Gate B has none.
  - Gate B's proof step (deploy, regenerate 837P from the fixed fixture set, diff it) cannot be replayed over history, so :prove_effect is counted as its own outcome and never scored as a pass or a fail.
  - The trigger document is TODAY's, replayed over historical trees. A pattern that matches nothing at an old ref escalates as a stale trigger — the gate working, on a question the replay invented. The configuration_applied stratum excludes those.
  - Only the :merge phase is replayed. The :triage run judges the trio's PREDICTED touches, and a replay has no prediction; substituting the real merged file list would bias that number optimistic.
