# Esh Planning Notes

This file is the index for durable engineering notes, audits, and implementation candidates that should stay attached to the repo.

## Current Notes

- [External Agent Patterns](./external-agent-patterns.md)
  Why it matters: identifies narrow patterns worth adopting into `esh` without dragging in platform complexity from broader agent systems.

## Near-Term Implementation Queue

1. Prompt cache normalization
2. Tool loop safety guard
3. Structured tool replay log
4. Scenario-style agent workflow tests
5. Thin MCP boundary design note

## Autonomous Coding Agent Roadmap

These are the additive phases needed to move `esh` from a context-aware local LLM CLI into a true autonomous coding agent.

### Goal

Make `esh` capable of handling real coding tasks end to end with:
- planning
- tool use
- code reads and edits
- build/test verification
- resumable task state
- bounded autonomy with explicit safety policy

### Phase A: Agent Core Foundation

Why it matters:
This is the main missing layer between the current context engine and a real agent.

What it needs:
- a bounded act-observe loop
- a first-class tool abstraction
- structured tool calls and tool results in model conversations
- a small safe built-in toolset for repo work
- agent-specific run integration

Status:
- in progress
- initial bounded agent loop and safe built-in tools should land first

### Phase B: Safe Code Editing

Why it matters:
Without reliable edits, the tool can inspect code but not operate like a coding agent.

What it needs:
- patch-based file editing
- multi-file edit support
- write conflict handling
- clear diff output
- additive file-write safety boundaries

Status:
- not started

### Phase C: Verification Loop

Why it matters:
Agentic coding quality depends heavily on edit-build-test-repair cycles.

What it needs:
- first-class build/test/lint tools
- verification criteria attached to tasks
- retry loop on failures
- stop conditions when blocked or unstable

Status:
- not started

### Phase D: Task Orchestration

Why it matters:
Longer coding tasks need durable progress state and resumability.

What it needs:
- explicit task phases
- blocked/failed/completed transitions
- resumable agent runs
- compact machine-usable working memory
- replayable tool traces

Status:
- partially started through run-state work
- not yet agent-grade

### Phase E: Agent UX

Why it matters:
A coding agent needs command surfaces that feel task-oriented, not just model-oriented.

What it needs:
- `esh agent run`
- future `esh fix`, `esh implement`, `esh continue`, `esh verify`
- compact run summaries and tool traces
- safe defaults for repo-scoped work

Status:
- not started

### Phase F: Retrieval and Language Precision

Why it matters:
Autonomy depends on stronger trust under ambiguous real coding tasks.

What it needs:
- broader ranking benchmarks
- parser/language-service backed reads where needed
- better disambiguation for broad queries
- optional semantic retrieval only if local precision still needs it

Status:
- in progress through current context-engine work

### Order Of Implementation

1. Phase A: Agent core foundation
2. Phase C: Verification loop
3. Phase B: Safe code editing
4. Phase D: Task orchestration
5. Phase E: Agent UX
6. Phase F: Retrieval and language precision

### First Additive Target

The first implementation target should be:
- a bounded `esh agent run <task>` loop
- structured tool protocol
- safe repo tools:
  - context planning/query
  - surgical reads
  - file listing/search
  - bounded shell verification commands

This gives `esh` the first real autonomous execution substrate without requiring a full IDE-like rewrite.

## Unfinished Context-Engine Phases

These are the context improvements that are still not finished after the recent MVP, surgical reads, and run-state work.

### Done So Far

- Phase 1: local workspace index
- Phase 2: heuristic ranking and query
  - path, basename, symbol, import, and content-token coverage
  - source-vs-test bias and recent git-history weighting
- Phase 3: surgical reads
  - `read symbol`
  - `read file --range`
  - `read references`
  - `read related`
- Phase 4 foundation: shared run state
  - `run start`
  - `run status`
  - `--run` logging from query and read commands
- Phase 3 additive planner integration
  - `context plan`
  - in-chat `/plan`
  - automatic local context briefs for `code`, `documentqa`, and `agentrun` chats
- Phase 4 additive synthesis
  - synthesized `run status` summaries
  - inferred open questions and next-step hints
- Phase 4 additive reasoning state
  - explicit run hypotheses, findings, pending tasks, completion tracking, and status updates
  - reusable machine-readable transitions in run synthesis
  - fresh run-aware summaries even when context packages are reused
- Phase 6 foundation
  - fixture-based `context eval` retrieval harness
  - repo fixture coverage in `Tests/Fixtures/context-eval.json`
- Phase 6 additive coverage
  - broader real-task retrieval fixture coverage across cache, run-state, model, and app-shell flows
  - richer retrieval metrics (`top5`, miss count, average first relevant rank)
- Phase 5 foundation
  - reusable context packages persisted from planning briefs
  - file-hash validation and invalidation
  - automatic reuse in `context plan` and code-style chat briefing
- Phase 5 additive cache linkage
  - cache artifacts can record context package identity, task fingerprint, file count, reuse status, and policy reason
  - `cache build` can resolve a context package for a task before selecting an automatic cache mode
  - cache inspection/load surfaces context-aware cache policy metadata
- Phase 4 additive compaction
  - synthesized runs now emit compacted focus files, focus symbols, and compacted summaries for longer investigations

### Still Unfinished

1. Better ranking signals
   Why unfinished:
   ranking now has broader fixture coverage and stronger source-vs-doc/test/command heuristics, but it is still heuristic and not parser- or behavior-aware.

   What remains:
   - stronger dependency, edit-history, and task-intent weighting
   - better disambiguation for broad or overloaded queries
   - retrieval quality validation on larger real-task suites

2. Parser-backed symbol and reference accuracy
   Why unfinished:
   extraction is lightweight and regex-oriented today.

   What remains:
   - tree-sitter or language-service backed indexing where it matters
   - more accurate symbol boundaries
   - better cross-file references and container relationships

3. Planner integration
   Why unfinished:
   the planning flow now has a local brief layer, but it is still lightweight and heuristic.

   What remains:
   - expand from brief generation into richer multi-step planning
   - learn when to skip or widen context automatically
   - connect planning outputs to future tool-loop execution safeguards

4. Shared run-state synthesis
   Why unfinished:
   run state now captures richer reasoning state, but longer-run synthesis is still lightweight.

   What remains:
   - preserve higher-level summaries across longer runs
   - connect reasoning state more directly to future tool-loop safeguards
   - add stronger compaction for long multi-step investigations

5. Cache-aware context packaging
   Why unfinished:
   reusable context packaging now reaches cache manifests and auto-mode policy, but it is still an early bridge rather than a full cache strategy.

   What remains:
   - reuse context-aware policy during more interactive chat/cache paths, not only cache build
   - expose package inspection and management more clearly in the CLI

6. Retrieval evaluation harness
   Why unfinished:
   the repo now has broader fixture-based coverage, but it still is not large enough to act as a full regression benchmark.

   What remains:
   - compare ranking changes with larger repeatable suites
   - measure token savings versus answer quality

7. Optional semantic retrieval layer
   Why unfinished:
   no embeddings or semantic retrieval layer exists yet.

   What remains:
   - decide whether semantic retrieval is needed at all
   - keep it optional and additive if introduced
   - avoid replacing the lightweight local index for common cases

## Rules For Future Planning Notes

- Prefer additive implementation candidates over rewrites.
- Record why a pattern fits or conflicts with `esh`.
- Include concrete files or modules worth studying.
- Mark whether a candidate should be done now or later.
