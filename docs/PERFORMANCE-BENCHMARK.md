# Performance Benchmark

This benchmark measures standard DevKit execution. It is not a reduced-validation or presentation path.

## Preparation

1. Activate the bot and install the approved UiPath CLI, skills, and pinned Graphify once.
2. Record setup separately from task execution. Do not include package/tool installation in the task result unless measuring first-use setup explicitly.
3. Start execution tracking from the bot root:

```powershell
$taskType = if (Test-Path project.json) { 'modification' } else { 'new_bot' }
./.rpa-ai/scripts/ExecutionState.ps1 -Action Start -TaskType $taskType -Json
```

## Straightforward New Bot

Use a small Process or REFramework bot with one clear input, one deterministic workflow, and no browser, Outlook, queue, database, or external-write dependency unless that capability is the scenario under test.

1. Provide the same intake and requirement to each run.
2. Record scaffold provenance and dependency setup.
3. Implement the approved behavior.
4. Run required diagnostics, restore or valid restore reuse, build, targeted functional validation, output QA when applicable, final graph synchronization, and the required audit route.
5. End with `Get-DeveloperRuntimeBreakdown.ps1 -Json`, `Test-ExecutionTimingConsistency.ps1 -Json`, then `ExecutionState.ps1 -Action Report -Json`.

## Localized Modification

Use a single existing workflow with unchanged interfaces, dependencies, and architecture. Record the changed workflow, direct caller/consumer, validation gates, cache reuse, and whether R1 no-audit eligibility applies.

## Broader Change

Use a multi-workflow, shared-component, dependency, interface, Config, REFramework, security, queue, database, or external-write change. Record the targeted/full Auditor route and any expanded validation. Do not classify it as R1 to improve the timing result.

## Official-only vs official + DevKit pilots

Run each pilot from the same starting source, input/expected result, installed official skill snapshot, CLI, framework, and package versions. Use official tooling in both arms for schema/capture/descriptor/authoring/validate/build/debug; the second arm adds DevKit approval, risk, Graphify, Target Registry, evidence, and output QA. Keep functional acceptance and required validation equivalent. Do not weaken checks to improve timing.

Record setup, cold execution, and warm/reuse execution separately. Reset the starting state between arms, identify cache/reuse conditions, and retain source/toolchain fingerprints and command evidence. For each arm measure functional success, elapsed time, tool calls, repair loops, and evidence completeness. Mock results test controls only; they cannot substitute for real-project results or support a speedup claim.

| Pilot | Required acceptance evidence |
| --- | --- |
| Deterministic CSV workflow | Same approved input and expected output; check CSV schema, row count, values, and readability of the produced file. Record official changed-file validate, build, applicable runtime, and output QA separately. |
| Development UI capture and reuse | Same approved Development URL, page state, and test data; prove native capture, descriptor-to-activity binding, the intended interaction, and a second reuse against the same target context. Static descriptors or mock bindings are not live UI proof. |

For `official-uipath-integration-01`, both pilots are `NOT_RUN` / `BLOCKED`: available examples are text only, with no executable pilot project, approved Development URL, or test data. Only the protocol and control-test evidence are available; no live-runtime comparison or measured speedup is claimed.

The Developer packet records fake CLI regressions: native validation `PASS` (21.702 s), diagnostics policy `PASS` (1.09 s), changed-workflow sanity `PASS` (0.819 s), and finalization initially `FAIL`, then `PASS` (14.788 s) after repairing the fixture to support required validate. These are control-test timings, not pilot timings. See `.ai/evidence/official-integration-developer-packet.json` and `.ai/evidence/official-integration-toolchain.json` for command logs and the real help-probe timeout.

## Required Measurements

Capture compact lifecycle state from `.ai/evidence/execution-state.json` and detailed non-overlapping events from `.ai/evidence/developer-events.jsonl`:

- functional outcome: `PASS`, `REWORK`, or `BLOCKED`;
- total wall seconds;
- active execution seconds;
- explicit user-wait seconds and pause/resume reasons;
- external-interruption seconds and interval reasons;
- every stage interval, including Coordinator handoff, scaffolding, Developer, validation, documentation, graph, Auditor, and finalization;
- command operation, duration, PID, exit status, timeout status, and external output artifact reference;
- source read/create/patch/write/replace/reopen/repair cycles, UIA and target lifecycle, Object Repository status, package/scaffolding, Mapper/Graphify, validation, evidence/state, and finalization timings;
- conservative `HOST_MODEL_OR_DISPATCH_GAP`, unknown residual, attributed runtime, and attribution coverage; this gap is observable idle time and does not prove model inference;
- repair-loop count and concrete failed evidence addressed;
- source, documentation, graph-configuration, and dependency fingerprints;
- Graphify `PASS`/`REUSED` and dependency `PASS`/`REUSED` status;
- audit route and independent Auditor result when required.

There is no time budget; elapsed time is measured, never enforced. Unfinished required work is `REWORK` or `BLOCKED`, never `PASS`.

## Report Format

```text
Scenario: NEW_BOT | LOCAL_MODIFICATION | BROADER_CHANGE
Environment: FIRST_USE_SETUP_SEPARATE | PREPARED
Functional outcome: PASS | REWORK | BLOCKED
Wall time: 00:00
Active time: 00:00
User wait: 00:00
External interruption: 00:00
Stages: <execution-state report>
Commands: <execution-state command evidence>
Repair loops: 0 / 1 / 2 / 3
Graph: PASS | REUSED
Dependencies: PASS | REUSED
Audit: SKIPPED_R1 | TARGETED | FULL
Bottleneck: <stage>
Attribution: <attributed>/<developer total>, <coverage>%
Timing consistency: PASS | WARN | FAIL
Limitations: <none or concrete limitation>
```
