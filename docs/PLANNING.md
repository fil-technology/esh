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
- Phase 3: surgical reads
  - `read symbol`
  - `read file --range`
  - `read references`
  - `read related`
- Phase 4 foundation: shared run state
  - `run start`
  - `run status`
  - `--run` logging from query and read commands

### Still Unfinished

1. Better ranking signals
   Why unfinished:
   current ranking is still mostly lexical and heuristic.

   What remains:
   - stronger symbol, path, recency, dependency, and edit-history weighting
   - better disambiguation for broad or overloaded queries
   - retrieval quality validation on real tasks

2. Parser-backed symbol and reference accuracy
   Why unfinished:
   extraction is lightweight and regex-oriented today.

   What remains:
   - tree-sitter or language-service backed indexing where it matters
   - more accurate symbol boundaries
   - better cross-file references and container relationships

3. Planner integration
   Why unfinished:
   context tools exist, but the planning flow does not automatically use them.

   What remains:
   - use ranked context during planning by default
   - inject surgical reads into task execution automatically
   - convert run-state discoveries into next-step suggestions

4. Shared run-state synthesis
   Why unfinished:
   run state is currently a ledger, not a reasoning layer.

   What remains:
   - summarize discoveries and decisions across a run
   - track open questions, hypotheses, and resolved findings
   - expose higher-level "what we already learned" outputs

5. Cache-aware context packaging
   Why unfinished:
   the context engine and KV/cache system are still mostly separate.

   What remains:
   - package stable retrieved context for reuse
   - align retrieval outputs with TurboQuant and TriAttention cache strategy
   - avoid rebuilding expensive context unnecessarily

6. Retrieval evaluation harness
   Why unfinished:
   there is no formal measurement loop for context quality yet.

   What remains:
   - benchmark query relevance and read usefulness across real repo tasks
   - compare ranking changes with repeatable fixtures
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
