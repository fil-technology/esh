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
- Phase 5 foundation
  - reusable context packages persisted from planning briefs
  - file-hash validation and invalidation
  - automatic reuse in `context plan` and code-style chat briefing

### Still Unfinished

1. Better ranking signals
   Why unfinished:
   ranking is better now, but it is still heuristic and not parser- or behavior-aware.

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
   reusable context packaging now exists, but it is still an early bridge rather than a full cache strategy.

   What remains:
   - connect context packages more directly to cache build/load flows
   - align packaged context reuse with TurboQuant and TriAttention policy decisions
   - expose package inspection and management more clearly in the CLI

6. Retrieval evaluation harness
   Why unfinished:
   the repo now has a fixture-based harness, but coverage is still small.

   What remains:
   - expand fixtures across real repo tasks
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
