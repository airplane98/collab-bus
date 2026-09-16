# Proposal: two review modes — author-fixes and finder-fixes

Status: **draft 3 — best-effort altitude (owner's choice); awaiting focused honesty check**
Kind: **workflow convention only. No envelope schema change, no code change.**

## History (kept so it is not re-derived)

- **Draft 1** claimed the bus made Mode 2 safe. False: the bus routes messages
  and observes agent state; **it does not arbitrate checkout ownership**, and it
  does not put two agents' turns in one global order. Clean commits are
  checkpoints, not writer exclusion.
- **Draft 2 and its review** identified a stricter design direction, with
  unresolved ownership transitions, crash recovery, and verification lifecycle.
  It was a direction, not a completed or verified airtight design.
- **Draft 3 (this)** takes the **best-effort altitude**: keep the cheap real
  protections, be precise about which risk each one covers, and state plainly
  what is NOT guaranteed. The stricter direction from draft 2's review is recorded in §Deferred
  as the upgrade path if Mode 2 ever proves load-bearing.

## The two modes

- **Mode 1 — author-fixes (current, default).** Reviewer reports; author applies;
  reviewer never edits the target.
- **Mode 2 — finder-fixes.** Whoever finds a defect may fix it, then hands the
  target back to verify. The pen follows the finding; it is turn-based.

## Best-effort safety: two risks, two protections, stated honestly

Mode 2 lets both sides write, and the bus cannot stop two writers clobbering each
other — it does not lock the checkout. At this altitude we do not make that
impossible; we aim to reduce the chance of loss and preserve recovery
checkpoints where possible, and we do not pretend otherwise. There are two DIFFERENT risks and they have DIFFERENT
protections — conflating them is the over-claim to avoid:

**Risk A — concurrent overwrite of UNCOMMITTED edits.** Two sides (or a
background formatter, or a second thread) writing one checkout at the same time.
- *Protection:* **one writer at a time, by cooperation.** Do not edit a checkout
  while it is handed to the other side; stop background writers on a handed-off
  checkout; a nudge timeout / peer idle / no reply does NOT mean the checkout is
  yours again.
- *Honest limit:* this is a discipline, not enforced. If it is violated,
  uncommitted edits may be lost. Git provides no recovery guarantee for them and
  cannot reconstruct overwritten content that was never recorded in Git.
  Previously staged or stashed content may sometimes survive, but this workflow
  does not rely on it. Best-effort means exactly this residual.

**Risk B — losing COMMITTED work** (a session dies mid-task; a bad merge,
mistaken reset, or force-push drops a commit).
- *Protection:* **commit creates a recovery checkpoint.** Commit before you hand
  off, AND commit before you stop actively editing. Previously committed content
  can often be recovered from retained history or surviving Git objects (located
  via a local reflog), **provided those objects still exist in an available
  repository or backup** — reflogs expire and unreachable objects may be pruned,
  so a commit is not a backup or an unconditional guarantee. Recovery restores
  *recorded* content, not unrecorded edits or external side effects. **No
  force-push / history rewrite** under this mode.
- This is where git can save you (Risk B), not Risk A; and a session dying
  mid-task loses any edits made after its last commit. A and B are the two risks
  this workflow targets, not an exhaustive taxonomy of every failure.

Two structural rules keep both honest:
- **git-only, judged by the review TARGET** (`git -C <target> rev-parse
  --show-toplevel`). The bus's own location is irrelevant to the test; without
  commits there is neither net nor safe handoff, so a non-git target is Mode 1.
- **Bus runtime lives OUTSIDE the target tree**, or publish/archive/bind writes
  into `collab/` re-dirty the tree after a fix commit and every clean-check
  fails on the bus's own noise. True for us: bus in the takumi workspace, target
  `~/collab-bus` — different trees. "Clean" covers the target tree only.

**Not airtight by design.** Separate worktrees per writer give *stronger
isolation of uncommitted source edits* (not the only such mechanism, and not a
cure for shared refs/config or effects outside the worktree), at the cost of
merges — that is the draft-2 path, deferred.

## Eligibility

git target (above); a project's own owner-rule forbidding reviewer writes (e.g.
takumi's deliverable rules) **overrides** a peer's `fix-policy` line; a repo
existing clears the gate but is not itself write authorization.

## Mode agreement (bilateral, or author-only)

- Initiator proposes `fix-policy: author | finder` in a fixed, non-repeated
  convention block in the body (a documented convention, not a gated field).
- **Finder requires the other side's explicit acceptance** before either writes;
  envelope compatibility is not mode capability. Until accepted → author-only.
- Every action / handoff / verify reply restates the mode, referencing the one
  accepted agreement; mode is never guessed from quoted text.
- **No silent fallback:** a missing or conflicting mode, or lost context, ⇒ stop
  and re-establish the agreement; do not each quietly revert to author (that
  changes who is writing). Switch modes only at a handoff boundary.

## Handoff

The handoff names the target repo/branch and the **result commit** (in `refs`)
and says what to verify. The receiver, **before any edit**, checks it is on the
expected branch/commit and the target tree is clean; on mismatch it **stops and
reports** — it never `reset --hard` / `clean` / overwriting `checkout` /
force-push to manufacture clean, and never stages someone else's edit into its
own handoff.

## Lifecycle (kept simple; step-5 compatible)

- `fix-applied` = a verification request (`intent: action`) pointing at the
  result commit. `type` is shape-gated, not an allowlist, and route keys on
  `to_agent`, so this new value needs no code.
- The verifier checks it and replies with one of: **clean**; **the fix is wrong /
  a new defect** (hand back with evidence — pen follows the finding); or **cannot
  verify right now** (say so plainly; do NOT fake a verdict and do NOT rewrite
  source to force one).
- **Pen follows the finding:** whoever finds a defect fixes it — unless it is a
  design or owner call, which is reported back instead. Mode 2 never pressures a
  bad fix.
- The original request **R is closed by R's recipient** with a single terminal
  reply, once its findings are all dispositioned (fixed-and-verified, reported
  back, or explicitly declined). One fix passing does not close R. This matches
  step-5 §5; consuming `outcome` in tooling stays deferred.

## What changes

**Docs only.** SKILL.md and the PROTOCOL template gain a "Two review modes"
section; the hard rule `不同時改同一檔` is **kept**, restated as "one writer per
checkout at a time; Mode 2 relaxes only 'the reviewer may never write', not the
one-writer rule." No envelope / route / participant / publish change; no script.
The live takumi bus stays Mode 1 (non-git root + owner-rule).

## Deferred — the stricter upgrade path (from draft 2's review, recorded not discarded)

If Mode 2 becomes load-bearing, upgrade to: an explicit ownership hand-off with a
state table (owner / writes-allowed / trigger / next owner); a crash-recovery
rule (an attempt record outside the tree, plus the handoff id carried in the
commit message, to close the commit→publish and publish→archive windows); and a
PASS / FAIL / INCONCLUSIVE verdict lifecycle with one terminal per verification
request. These are consciously NOT built at best-effort altitude.

## For Codex — focused honesty check (not a re-litigation of altitude)

The best-effort altitude is the owner's decision; the three gaps you found
(ownership transitions, crash recovery, non-pass lifecycle) are consciously
ACCEPTED here, not solved. Please check only:

1. Is the framing HONEST — no residual claim that the bus prevents a lost edit,
   and is the Risk A / Risk B split accurate (git recovers committed work, NOT
   an uncommitted concurrent clobber)?
2. Does best-effort have a hole that git recoverability does NOT actually cover
   AND that a reader would reasonably think it does? (i.e. a place the doc still
   over-promises.)
3. Is anything in §Deferred misrepresented as done, or would landing this as
   docs paint step 5 into a corner?
