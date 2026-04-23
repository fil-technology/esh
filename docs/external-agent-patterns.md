# External Agent Patterns For Esh

Repository audited:
- external open-source agent repository
- commit: `b1eff5f7f951c85cddfc9cadc649bbfbb4ec4f99`

Purpose:
- preserve the audit findings from the external repository review
- keep only the ideas that fit `esh`
- make tomorrow's implementation planning concrete

## Executive Conclusion

`esh` should borrow narrow patterns, not architecture.

The audited project is a broad agent platform with CLI, server, desktop, MCP, ACP, local inference, scheduling, telemetry, and extensions. `esh` is better served by stealing a few small, high-value ideas that improve reliability, cache efficiency, and extensibility.

## Adopt Now

### 1. Prompt Cache Normalization

Why:
- directly fits `esh`'s MLX, TurboQuant, and KV-cache direction
- reduces prompt volatility and improves cache reuse

Smallest viable version for `esh`:
- sort tool and extension descriptors deterministically before prompt assembly
- avoid unstable prompt fields where possible
- coarsen any required timestamps to a stable bucket when safe

Study:
- prompt manager module in the audited repository

ROI:
- implementation complexity: low
- dependency risk: low
- additive: yes
- fit with `esh`: strong

### 2. Tool Loop Safety Guard

Why:
- prevents repeated identical tool calls from wasting turns, tokens, and time
- improves reliability cheaply

Smallest viable version for `esh`:
- track identical tool calls per run
- abort or require intervention after configurable repetition threshold

Study:
- tool monitor module in the audited repository

ROI:
- implementation complexity: low
- dependency risk: low
- additive: yes
- fit with `esh`: strong

### 3. Subprocess Hygiene And Env Sanitization

Why:
- `esh` is execution-heavy, so child process behavior matters a lot
- better isolation and env filtering reduces fragile failures

Smallest viable version for `esh`:
- isolate child processes into their own group where appropriate
- enforce safe env override rules
- normalize cancellation and shutdown behavior

Study:
- subprocess module in the audited repository
- extension configuration module in the audited repository

ROI:
- implementation complexity: low
- dependency risk: low
- additive: yes
- fit with `esh`: strong

### 4. Scenario-Style Agent Workflow Tests

Why:
- agent regressions are usually behavioral, not unit-level
- `esh` needs workflow validation more than feature-count growth

Smallest viable version for `esh`:
- record or simulate a few headless runs
- assert behavior over ask, tool, observe, finish flows
- use mocked tools where possible

Study:
- scenario runner module in the audited repository

ROI:
- implementation complexity: medium
- dependency risk: low
- additive: yes
- fit with `esh`: strong

## Adapt Later

### 5. Provider Registry Metadata Pattern

Why:
- helps keep `esh` provider-agnostic cleanly
- centralizes model/provider capability metadata

Smallest viable version for `esh`:
- add provider metadata and capability declarations
- avoid tying registry changes to session/runtime behavior

Study:
- provider registry module in the audited repository
- provider base module in the audited repository

ROI:
- implementation complexity: medium
- dependency risk: low
- additive: yes
- fit with `esh`: good

### 6. Structured Tool Result Serialization

Why:
- useful for replay, debug, traces, and future evaluations
- improves observability without heavy telemetry infrastructure

Smallest viable version for `esh`:
- define stable JSON for tool request/result persistence
- use it in run logs and test fixtures

Study:
- tool result serialization module in the audited repository

ROI:
- implementation complexity: low to medium
- dependency risk: low
- additive: yes
- fit with `esh`: good

### 7. Thin MCP Boundary

Why:
- useful for future extensibility
- should be kept narrow so `esh` does not become a broad agent platform

Smallest viable version for `esh`:
- support `stdio` and `streamable_http`
- keep a minimal loader and tool adapter
- avoid frontend, server, desktop, or full platform-extension layers

Study:
- extension manager module in the audited repository
- MCP client module in the audited repository
- extension config module in the audited repository

ROI:
- implementation complexity: medium
- dependency risk: medium
- additive: yes, if narrow
- fit with `esh`: conditional

## Useful Concepts, But Do Not Implement Directly

### Conversation Compaction By Summarization

Why not:
- this is not a substitute for a real codebase context engine
- `esh` should prefer retrieval and surgical reads over summarizing away structure

Study only:
- context compaction module in the audited repository

### Recipe System

Why not yet:
- useful conceptually, but easy to expand into product sprawl
- `esh` should first stabilize execution, context, and cache behavior

Study only:
- recipe module in the audited repository

### Subagent Framework

Why not yet:
- adds orchestration complexity fast
- not required for `esh`'s current CLI direction

Study only:
- subagent handler module in the audited repository

## Not Useful For Esh

### Alternative Local Inference Stack

Why not:
- built around GGUF and `llama.cpp`
- `esh` should stay MLX-first on Apple Silicon

Avoid copying:
- local inference provider module in the audited repository
- local inference server route in the audited repository

### Product Platform Surface

Why not:
- server, desktop UI, gateway, dictation, and app surfaces do not help the core `esh` CLI

Mostly irrelevant:
- server modules in the audited repository
- UI modules in the audited repository
- built-in MCP server modules in the audited repository

### LLM-Based Permission Classification

Why not:
- clever, but too opaque
- `esh` should prefer deterministic approval policy

Avoid copying:
- permission judge module in the audited repository

## Tomorrow's Likely First Implementation Order

1. Prompt cache normalization
2. Tool loop safety guard
3. Structured tool replay log
4. Scenario workflow tests

## Direct `esh` Design Constraints To Preserve

- do not rewrite `esh` around an external platform architecture
- prefer additive changes over subsystem replacement
- stay local-first and Apple-Silicon-first
- keep MLX and cache reuse as first-class strengths
- avoid turning `esh` into a desktop-heavy platform
- context engine work should stay repo-aware and surgical
