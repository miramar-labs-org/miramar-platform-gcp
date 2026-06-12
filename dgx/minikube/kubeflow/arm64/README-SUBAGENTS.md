# Multi-Session Build Architecture (KFP arm64 Port)

How to run a build too large for one context window — the full Kubeflow Pipelines
arm64 port — without hitting the context limit. Three layers, each handling a
different slice of the "this task is bigger than one window" problem.

## The problem

A full multi-arch port generates enormous context: Dockerfile edits, Bazel/buildx
logs, dependency hunts, registry pushes — per image, times a dozen images. Done in
one session it overflows the window (and trips the 1M-context billing wall). The
fix isn't a bigger window; it's an architecture that keeps each unit of work small
and puts the connective tissue on disk.

## The three layers

| Layer         | What it is                                                                                                         | Solves                                                        |
| ------------- | ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------- |
| **Plan file** | `KFP-ARM64-PORT-PLAN.md` — a dependency-ordered, per-component checklist on disk                                   | Crossing session boundaries; the durable spine                |
| **Sub-agent** | `arm64-builder` (`.claude/agents/arm64-builder.md`) — builds ONE image in its own context, returns a short summary | Verbose build output never touches the orchestrator's context |
| **Handoff**   | Your existing `/handoff` → vault system                                                                            | When a single component's session itself runs long            |

Each layer is independent; together they let session 12 start as fresh as session 1.

## Layer 1 — the plan file

A Markdown checklist, one step per component, written so that **each step is a
self-contained assignment a fresh worker could execute having read only the plan**.
Every step states: component name, source image + exact version, arm64 build
approach, anticipated gotchas, target registry tag, a verification step, and a
status checkbox.

Steps are **dependency-ordered** and marked `[PARALLEL-SAFE]` or `[BLOCKED BY: N]`.
That marking drives everything downstream: parallel-safe steps fan out to
concurrent sub-agents; blocked steps run in order.

Location: `/home/aaron/shared/VAULT/handoffs/miramar-platform-gcp/KFP-ARM64-PORT-PLAN.md`
(in the vault, so it's readable from any machine and survives context resets).

The plan is generated once by an orchestrator session (see "Generating the plan"
below), reviewed by you for dependency-order sanity, then becomes the source of
truth that every build session reads from and writes back to.

## Layer 2 — the arm64-builder sub-agent

Defined at `.claude/agents/arm64-builder.md` (project scope, so it's committed,
shared, and inherits the project `CLAUDE.md` context automatically).

The orchestrator delegates one component to it via the Task tool. The sub-agent:

- Runs in its **own isolated context window** — its build logs never reach the
  orchestrator.
- Has `isolation: worktree`, so parallel builders get separate git worktrees and
  can't clobber each other's working tree.
- Reads its component's step from the plan, builds for `linux/arm64` natively on
  the DGX, verifies, pushes to `ghcr.io/miramar-labs-org/<image>:<tag>`, and
  updates its checkbox in the plan.
- Returns **only a short structured summary** (component / status / image tag /
  new gotchas / next) — that brevity is the whole point.
- Returns `STATUS: blocked` with a question rather than guessing on a genuinely
  ambiguous build choice (a wrong build wastes a downstream session).

### Key limits to remember

- **The orchestrator's own context still grows** with each returned summary. Sub-
  agents shrink the problem hugely but don't make the orchestrator window infinite
  — when it fills, the plan file is the handoff to a fresh orchestrator session.
- **Sub-agents can't spawn sub-agents** — no nested delegation.
- **No real-time shared context** — sub-agents don't see each other's work; if A's
  result changes B's task, wait for A and re-delegate B.
- **Cost multiplies** — N parallel sub-agents ≈ N× tokens for that span. Route
  workers to a cheaper model with `export CLAUDE_CODE_SUBAGENT_MODEL=<model>` while
  keeping the orchestrator on a stronger one.

## Layer 3 — handoffs

For when an individual component's build session itself turns into a multi-session
slog. Use your existing `/handoff` command; it captures the in-flight detail into
the vault. The plan tracks *what's done across the port*; a handoff captures *the
messy state inside one hard component*.

## Generating the plan

In a fresh orchestrator session, give Claude Code a prompt that:

1. Surveys reality first — reads `.claude/agents/arm64-builder.md` (so plan steps
   match what the sub-agent expects as input), the build/deploy workflows, the
   arm64 README, and the KFP kustomize manifests to enumerate every image.
2. Writes the dependency-ordered, self-contained, `[PARALLEL-SAFE]`/`[BLOCKED BY]`
   plan to the vault path above.
3. Does **not** build anything or spawn sub-agents — produces only the plan, then
   shows the step list for you to sanity-check sequencing.

(The exact prompt lives alongside this doc / in your notes.)

## Running the port

1. **Generate the plan** (above). Review the step list — especially the dependency
   order. The MLMD pair is already built and is an upstream dependency for much of
   the rest, so confirm nothing parallel-safe secretly depends on an unbuilt image.
2. **Build, per orchestrator turn:**
   > "Read KFP-ARM64-PORT-PLAN.md and delegate the unblocked parallel-safe
   > components to arm64-builder concurrently. Walk the blocked chain in order."
   The orchestrator fans out sub-agents, collects summaries; build logs stay in the
   sub-agents' contexts.
3. **Watch the orchestrator's context percentage.** When it climbs, stop. The plan
   already records what's done — start a fresh orchestrator session and resume from
   the plan.
4. **Repeat** until every component is checked off, then run **Kubeflow Deploy**
   (which patches the MLMD/KFP stack to the arm64 images you've built).

## Why this works

Each *unit* of work is small: a sub-agent build, or a single plan step. The
*state* lives on disk (the plan), not in any one context window. So no session
ever has to hold the whole port — and you never hit the wall mid-build with no way
to resume cleanly.

## Files

| File                     | Location                               | Role                                              |
| ------------------------ | -------------------------------------- | ------------------------------------------------- |
| `arm64-builder.md`       | `.claude/agents/` (repo)               | Sub-agent definition; committed with the repo     |
| `KFP-ARM64-PORT-PLAN.md` | `VAULT/handoffs/miramar-platform-gcp/` | The plan / cross-session spine                    |
| handoff commands         | `~/.claude/commands/`                  | `/handoff`, `/resume-handoff` for hard components |
