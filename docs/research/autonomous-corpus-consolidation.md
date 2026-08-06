# Autonomous corpus consolidation: the prior art, and what loopctl actually built

Research notes behind the nightly consolidation pass (#584, #605) — the "dream." Written
after the 2026-08-05 session that made the machinery self-draining, and kept because the
reasoning is more reusable than the code.

The short version: **the idea is old, the failure mode is specific, and the escape from it
is reversibility rather than intelligence.**

---

## 1. Why a corpus needs a dream at all

A knowledge base written by many agents, continuously, degrades in ways none of the writers
can see. Each write is locally correct. The damage is emergent:

- the same knowledge captured twice under slightly different titles
- a wrong rationale attached to a right conclusion, which reads as correct until the two are
  quoted side by side
- entries that were true and quietly stopped being true
- placeholder titles that block structure from forming

None of these is detectable at write time, which is exactly why an offline pass exists.
Anthropic ships consolidation as an offline batch for managed agents for the same reason.

---

## 2. The prior art, oldest first

### Complementary Learning Systems (1995)

McClelland, McNaughton & O'Reilly. The hippocampus learns fast and episodically; the
neocortex learns slowly and structurally; **replay during sleep** transfers between them.
This is the direct biological ancestor of "dream," and it exists to answer a specific
problem: McCloskey & Cohen's **catastrophic forgetting** (1989), where naive sequential
learning destroys what came before.

The load-bearing detail people skip: CLS replay is not cleanup. It is *interleaved replay to
extract structure* — the neocortex generalises across episodes. A pass that only removes
duplicates is doing hygiene, not consolidation.

### Wake-Sleep (1995)

Hinton, Dayan, Frey & Neal named the two phases outright. A wake phase that acts, a sleep
phase that reorganises what the wake phase produced.

### Experience replay (1992 → present)

Lin (1992), then DQN (Mnih et al., 2015). **Prioritised experience replay** (Schaul et al.,
2016) adds the rule a nightly pass should steal: *replay what is surprising*, not everything.
Our pass currently scans the whole corpus every night, which is the un-prioritised version.

### Generative replay (2017)

Shin et al. — replay generated samples rather than stored ones, to consolidate without
keeping the raw data. Relevant to the transcript question below.

### Agent memory (2023 → present)

- **Generative Agents** (Park et al.) — a memory stream plus a periodic **reflection** step
  that synthesises higher-level insights. This is the closest published analogue to what
  loopctl calls consolidation.
- **MemGPT** (Packer et al.) — hierarchical memory with paging between context and store.
- **Reflexion** (Shinn et al.) — self-critique written back into episodic memory.

### The two older fields that matter more

**Record linkage — Fellegi & Sunter (1969).** The formal treatment of duplicate detection,
and it makes a *three-way* decision: match, non-match, and **possible match requiring
clerical review**. Thresholds are tuned to bound both error rates, and the middle zone is
where a human goes.

That middle zone is exactly loopctl's 16,117 flagged pairs. We have no clerical reviewer, so
we escape the zone a different way — see §4.

**Belief revision — Doyle's Truth Maintenance Systems (1979) and the AGM postulates
(Alchourrón, Gärdenfors & Makinson, 1985).** The formal theory of what to do when new
information contradicts what you already hold. AGM's *minimal change* principle is arguably
what a `:supersede` disposition should obey, and currently does not.

**Wikipedia's bot policy** — the operational precedent nobody cites. Autonomous corpus
maintenance at scale, solved empirically: bots must be approved, rate-limited, run a trial
period, and **every action must be revertible by the community**. They arrived at
reversibility-as-licence independently, from experience rather than theory.

---

## 3. The failure mode we actually hit

Every defect found in the 2026-08-05 audit was the same shape: **a producer with no
consumer.**

| Queue | Producers | Automatic consumers |
|---|---|---|
| drafts | 7 | 0 |
| `potential_conflict` | 2 | 0 — monotone by construction |
| `:supersede` below `:high` confidence | 1 | 0 — invisible *and* unexecutable |

In all three the imagined consumer was a human, and the human never came. Measured
consequences: 16,117 open conflicts that had **never** produced a single resolution in the
corpus's lifetime; 81 published articles unsearchable for six weeks while an hourly
reconciler reported healthy; 26 stranded drafts, two of which arrived *during* the audit.

The lesson is not "humans are needed." It is the opposite: **the human was already absent,
and the system was designed as though they weren't.** "Approve before write" was not a safety
property, it was an unfunded liability, and the corpus degraded precisely *because* it was
waiting.

---

## 4. What replaces the reviewer

Three substitutions, in the order they matter.

### Reversibility instead of approval

A reviewer's real job in "approve before write" is to be the safety mechanism for an
**irreversible** act. Make the act reversible and the requirement dissolves.

This is why the archive-vs-unpublish distinction turned out to be the load-bearing detail of
the whole design, not the proposal logic: `:archived` is terminal for an article, so nothing
automated can undo it; `{:published, :draft}` is reversible, so an unattended pass may use
it. **A class earns auto-apply by being reversible, not by being confident.**

It is also the same conclusion Wikipedia's bot policy reaches.

### Agreement instead of confidence

A proposal applies only when **two consecutive runs** independently produce it. Anything
transient — a duplicate created and cleaned up between runs, a title edited mid-scan, a
half-finished import — is gone by the next night and is never acted on.

This is deliberately *not* a confidence score. Confidence is the machine grading its own
homework. Agreement across two independent observations of a moving corpus is evidence. It
costs one night of latency and removes most of what a reviewer actually catches.

### Honesty instead of fabricated verdicts

The worst defect found was not a missing human. It was the machine **claiming a judgement it
could not make**.

`potential_conflict` was promoted on cosine similarity ≥ 0.93. Similarity says *"these say
the same thing."* Contradiction says *"these disagree."* Those are orthogonal — a flat
contradiction scores high, but so does every honest restatement — so a similarity threshold
cannot separate them.

Measured across all 16,117 flagged pairs: 0 identical bodies, 261 identical normalised
titles, 54% within 10% body length. A 20-pair sample spanning 0.93–0.99 contained **zero**
contradictions. The top matches differed by a colon, a hyphen, a percent sign and a plural.

It was **redundancy**, mislabelled as disagreement — and the consequence was inverted: an
open conflict suppressed *both* its articles from curated answers, so the system withheld its
most-corroborated content. The fix was to record `classification: :redundant`, which the
schema already had vocabulary for and the promoter had never used.

**An autonomous system fails when it fabricates verdicts. It works when it records what it
actually measured.**

### Convergence as arithmetic

The drain is capped *above* the producer (2,000 judged vs 500 promoted per night), so the
backlog falls rather than holding at whatever level it reached. That is subtraction, not
judgement, and it is the only part of the design that needs no reasoning to verify.

---

## 5. The transcript question, and why it stayed client-side

Consolidation can only reconcile what is *in* the corpus, but session transcripts live on
the machines that produce them. Two options:

(a) capture keeps extracting client-side; the pass consolidates published articles only
(b) capture ships raw transcript excerpts server-side; the server does extraction *and*
    consolidation

**(a), decided deliberately.** A 2026-08-04 harvest found live API keys sitting in raw
source material, so shipping transcripts server-side is an egress decision to be made on its
own merits — not inherited as a side effect of a consolidation feature. (a) is also the
reversible direction: (b) remains available later, while an accidental (b) cannot be undone.

Generative replay (§2) is the research answer to wanting (b)'s benefits without its risk.

---

## 6. Where this is still thin

**The classes that are cheap to detect are the ones that matter least.** Duplicates dominate
by volume and are trivially findable. The defect that motivated the whole feature — a *wrong
rationale attached to a right conclusion* — has **no detector at all**, because it reads as
perfectly consistent prose and similarity cannot see it.

**Nothing generalises.** Per CLS, consolidation's real function is extracting structure
across episodes. Our pass removes duplicates and closes conflicts; nothing reads N related
articles and produces the abstraction they share. That is the actual dream, still unbuilt.

**The scan is un-prioritised — and that turned out not to matter.** This section previously
argued the opposite, and the correction is worth keeping because it is the cleanest example
in the whole exercise of a fix that reasoned beautifully and measured to nothing.

The argument was: ~79,000 articles scanned nightly to find a few hundred things, two of the
three scans `GROUP BY regexp_replace(...)` and therefore unindexable, and only ~20 articles
changed that day. Prioritised replay says scan the *delta*. Every step of that is true. Then
it was timed on the hosted corpus, and the whole set came back in **a few seconds, once a
night**, on a pool provisioned for exactly this. There is no cost to recover.

(The live figure belongs in one place and this is not it — `Loopctl.Knowledge.Consolidation`'s
moduledoc carries the current per-scan timings, and it has already moved once as predicates
were folded together. A number copied into a research note is a number that will be wrong
here while being right there.)

Worse, building it would have *cost* correctness. Auto-apply requires two consecutive runs to
propose the same group; a delta scan drops any group whose articles did not change between
runs, so the confirmation gate could never close unless the delta window exceeded the run
interval. And a duplicate pair nobody has touched in a year — the bulk of what the class
finds — would never be scanned again at all.

The generalisable part: **"this scan is O(corpus) and the corpus is large" is an argument
about shape, not about cost.** It feels like a finding because the asymptotics are real. It
is only a finding once a stopwatch agrees. If the scan does become slow, the answer is an
expression index on the normalisation, not a narrower scan — the plan is a sequential scan
plus a 9 MB external-merge sort, both of which an index removes without touching semantics.

**A time threshold is not a correctness signal — so the class was cut.** `:stale_entry`
produced hundreds of proposals a night that nothing could ever act on: "nobody edited this in
N days" says nothing about whether it is wrong, and auto-archiving on age would silently
delete the corpus. It was a fourth queue with no consumer, just slower to notice.

It is now retired. The deciding argument was not that it was useless but that it was
*redundant*: the lint engine computes stale articles itself and publishes them on its own
endpoint with a caller-chosen threshold, so consolidation was re-rendering one signal into a
capped report whose other slots go to classes something can act on. Removing it cost no
information at all — which is the easiest kind of queue to close, and worth looking for
before arguing about the hard ones.

---

## 7. What to steal from this

1. **Count your producers and consumers.** A queue whose only consumer is a human nobody
   staffs is not a safety mechanism, it is a leak. This codebase had three simultaneously.
2. **Check what your signal actually measures** before naming the class it produces. The
   name outlives the check.
3. **Make the act reversible and the approval becomes optional.** Reach for the reversible
   primitive even when the terminal one is more satisfying.
4. **Two independent observations beat one confident one**, and cost only latency.
5. **Measure before fixing.** In one session, measurement killed four fixes that were
   confidently designed and would have been shipped: a lint result-set bound (the "unbounded"
   scan was ~500 rows), a producer throttle (its output never reached the consumer), a claim
   that 32k article-slots were being actively withheld (the curated set was empty, so the harm
   was latent rather than live), and the delta scan above (2.9 s/night, and it would have
   broken the confirmation gate). The pattern in all four: a defect argued from *shape* —
   unbounded, uncapped, O(n), redundant — that a stopwatch or a `count(*)` then declined to
   confirm. Shape tells you where to point the instrument, never what it will read.

---

## References

- McCloskey & Cohen (1989), *Catastrophic Interference in Connectionist Networks*
- Doyle (1979), *A Truth Maintenance System*
- Alchourrón, Gärdenfors & Makinson (1985), the AGM postulates for belief revision
- Fellegi & Sunter (1969), *A Theory for Record Linkage*
- McClelland, McNaughton & O'Reilly (1995), *Why there are complementary learning systems in
  the hippocampus and neocortex*
- Hinton, Dayan, Frey & Neal (1995), *The Wake-Sleep Algorithm for Unsupervised Neural
  Networks*
- Lin (1992), experience replay; Mnih et al. (2015), DQN; Schaul et al. (2016), *Prioritized
  Experience Replay*
- Shin et al. (2017), *Continual Learning with Deep Generative Replay*
- Park et al. (2023), *Generative Agents* — the reflection mechanism
- Packer et al. (2023), *MemGPT*; Shinn et al. (2023), *Reflexion*
- Wikipedia: Bot policy / Bot Approvals Group — the operational precedent
