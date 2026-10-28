---
description: Explicit R0-R3 audit routing, R1 no-audit eligibility, abbreviated Coordinator/Developer/Auditor procedures, the unified risk/lane matrix, and escalation rules for low-risk changes.
applyTo: "**"
---
# Risk Lanes and Audit Routing

This is the single authoritative source for R0 Fast Lane and R1 Light Lane rules. Agent prompts reference this file rather than duplicating it. R2–R3 keep the full existing lifecycle unchanged. R0 Fast Lane and R1 Light Lane are abbreviated branches reached only through an explicit, conservative eligibility check, not replacement workflows.

> R0 reduces gates because the change is non-behavioral. R1 keeps applicable gates but narrows scope because the change is low-risk and localized. R2 uses the normal workflow. R3 expands assurance because the change is high-risk. The goal is work proportional to risk and impact, not universal speed.

**Same governance, less duplicated work.** Low-risk `AUDIT_MODE: NONE` removes only the independent Auditor invocation after the Developer satisfies a stricter evidence gate. It never removes human approval, managed-core integrity, deterministic validation, capability gates, evidence, traceability, or Production restrictions.

## Execution tracking

Every task starts `.rpa-ai/scripts/ExecutionState.ps1` before repository-specific analysis. It persists wall-clock timestamps, stage intervals, and command evidence under `.ai/evidence/execution-state.json` for reporting. There is no time budget: elapsed time never stops work, skips a gate, or changes the outcome. `ExecutionState.ps1 -Action RepairStart` enforces `max_repair_loops: 3`.

Report total wall time, active execution time, and explicit user-wait time. Use `Pause`/`Resume` only for explicit user decisions. Supported long-running commands run through `Invoke-DevKitCommand.ps1`, which applies a fixed per-command safety timeout and records duration, exit status, timeout, and available output.

## Audit mode routing

### Automatic environment repair

Environment and prerequisite repair never requires approval. Fix recoverable problems automatically (runtime install, package restore, tool reinstall, graph rebuild), retry the failed gate, and continue. Optionally bracket the work with `ExecutionState.ps1 -Action EnvironmentStart -Reason <scope>` and `EnvironmentEnd -PhaseStatus PASS|BLOCKED` so setup time is reported separately; this is a timing marker only and never authorizes business authoring. Stop only on an actual unresolved information/environment/safety blocker or after the repair-loop cap; never report a scaffold as the requested business automation.

Every Change Plan records:

```text
RISK_LEVEL: R0 / R1 / R2 / R3
AUDIT_MODE: NONE / LIGHT / FULL
AUDIT_REASON: <factual reason>
```

Default routing:

| Risk | Default audit mode | Rule |
| --- | --- | --- |
| R0 | NONE | Non-behavioral work; route to audit only if invalidated or escalated. |
| R1 | NONE or LIGHT | `NONE` requires every `R1_NO_AUDIT_ELIGIBLE` condition; otherwise `LIGHT` unless a full-audit trigger applies. |
| R2 | LIGHT or FULL | Auditor is mandatory; never `NONE`. |
| R3 | FULL | Auditor is mandatory; never `NONE`. |

`AUDIT_MODE: NONE` is a routing decision, not an Auditor PASS. Report the Auditor as skipped and complete only after the applicable Developer gates and self-review pass.

When `AUDIT_MODE` is `NONE`, do not generate an Auditor verdict, validation marker, evidence item, PASS status, or independent-review claim. Report only `Independent Auditor: SKIPPED`. When `AUDIT_MODE` is `LIGHT` or `FULL`, report the invoked Auditor's actual result.

Mandatory audit triggers override the initial route. Set `AUDIT_MODE` to at least `LIGHT`, or `FULL` when the trigger is high risk:

- `project.json` or dependency changed;
- shared component changed;
- workflow argument/interface changed;
- Config semantics changed;
- REFramework architecture changed;
- retry, transaction, exception classification, or queue behavior changed;
- database or material external-system write changed;
- security-sensitive logic or credential handling changed;
- Production configuration or environment touched;
- unexpected file changed or Developer modified outside the approved Impact Set;
- build failed, a required targeted test failed, or a required test could not be performed and remaining risk is material;
- validation evidence is missing, stale, or inconsistent;
- source changed after final validation;
- Developer identifies uncertainty or the Coordinator cannot confidently classify the change as low risk.

`AUDIT_MODE` must not remain `NONE` after a trigger. A Light Auditor may return `ESCALATE_TO_FULL_AUDIT` when independent review finds deeper risk.

## 1. What R0 means

> A trivial or non-behavioral change that cannot alter runtime behavior, interfaces, dependencies, deployment behavior, external interaction, security, or business logic.

May qualify: comments, spelling corrections, Markdown/documentation formatting, README wording, harmless metadata, internal instruction wording that does not change executable behavior, cosmetic documentation restructuring, dead text/comment cleanup, formatting-only changes, test *description* wording that does not change test execution.

## 2. Explicit exclusions (never R0)

`.xaml`/coded workflow logic; conditions; assignments; behavior-affecting arguments/variables; Config values that affect execution; selectors; browser/UI interaction; email behavior; Excel/output-generation behavior; dependency or `project.json` changes; application/API/database/queue/Orchestrator interactions; credentials; Production resources; file movement/deletion/external writes; business rules; exception/retry handling; logging that affects operational monitoring/contracts; test *logic*; architecture; interfaces; deployment settings; security-related instructions; managed-core protection rules.

Risk is determined by impact, not size. A one-line change is never R0 merely because the diff is small, one file changed, it looks easy, it is quick, or the user asked for something fast. When uncertain, classify conservatively:

```text
R0_FAST_LANE_ELIGIBLE: false
```

and use the normal R1–R3 workflow.

## 3. Eligibility matrix (guidance, not exhaustive)

| Change | Risk | Fast Lane |
| --- | --- | --- |
| README typo | R0 | YES |
| Markdown formatting | R0 | YES |
| Comment-only change | R0 | YES |
| Documentation wording, no semantic change | R0 | YES |
| Non-runtime metadata | R0 | Usually YES |
| Test description wording (execution unchanged) | R0 | Usually YES |
| New workflow | not R0 | NO |
| XAML condition change | R2 | NO |
| Isolated selector or normal browser interaction with complete capture evidence | R1 when interfaces, dependencies, architecture, security, and cross-component contracts are unchanged; otherwise R2 | NO |
| Config value affecting execution | R1/R2 | NO |
| Dependency change | R2 | NO |
| Business rule | R2 | NO |
| Queue/DB/external write | R3 | NO |
| Security/credential change | R3 | NO |

## 4. Coordinator: eligibility check and concise plan

`risk_level: R0` alone is never permission to use the Fast Lane. Record, in the Change Plan:

```text
RISK_LEVEL: R0
R0_FAST_LANE_ELIGIBLE: true | false
R0_FAST_LANE_REASON:
<concise factual justification>
```

When eligible, replace the full Executable Change Plan with a concise plan and skip multi-option solution selection (state directly that a single non-behavioral correction is proposed):

```text
change_id:
risk_level: R0
r0_fast_lane:
  eligible: true
  reason: ...
objective:
scope:
  modify:
  verify:
  do_not_modify:
runtime_behavior_changed: false
dependencies_changed: false
ui_behavior_changed: false
external_interfaces_changed: false
documentation_impact: NONE | CONTEXT_ONLY | HUMAN_DOCS
validation:
  targeted_diff_check: true
  managed_integrity: true
  build_required: false
  analyzer_required: false
  functional_tests_required: false
evidence_required:
  - diff
  - changed-file inspection
  - integrity result
```

Human approval is still mandatory and may be concise:

```text
Recommended change: <one line>
Risk: R0
Fast Lane: Eligible
Runtime impact: None
Executable files affected: None
Dependencies: Unchanged
Testing required: Targeted documentation/diff validation only
```

Do not skip a gate merely because the task was initially labeled R0; eligibility must be validated by the Coordinator and Developer. R0 uses `AUDIT_MODE: NONE` by default, so no independent Auditor invocation is required unless a trigger appears.

## 5. Developer: abbreviated procedure

```text
Receive approved R0 plan
  → verify changed-file scope
  → confirm non-behavioral classification
  → make the minimal requested change
  → inspect the diff
  → run applicable lightweight deterministic checks
  → produce concise evidence
```

Do not repeat project discovery, reanalyze architecture, inspect unrelated XAML, run package restore, perform UI capture, run UiPath build/analyzer, execute functional tests, or inspect output artifacts unless the actual change unexpectedly makes one of these relevant. `DEPENDENCY_SETUP_REQUIRED`, `UI_CAPTURE_REQUIRED`, and `OUTPUT_QA_REQUIRED` stay `false`/not applicable when the change genuinely has no such surface.

### Mandatory Developer escalation

If any runtime-impacting change is discovered (for example the diff also touches `.xaml`, a Config execution value, a dependency file, or test/operational logic), invalidate the Fast Lane immediately:

```text
R0_FAST_LANE_INVALIDATED: true
Reason:
<what was discovered>
Recommended risk:
R1 | R2 | R3
Required workflow:
NORMAL
```

Continue the task through the normal R1–R3 workflow; do not keep using the Fast Lane after invalidation.

## 6. Minimal R0 deterministic validation

Mandatory baseline for every R0 Fast Lane change:

1. changed-file/diff verification;
2. managed-file integrity where applicable;
3. repository consistency/cross-reference check where applicable.

Do not automatically require restore, build, Workflow Analyzer, functional tests, UI validation, or output-artifact QA when no executable/runtime artifact is affected. Report genuinely irrelevant checks as `NOT_APPLICABLE`, never as `PASS`:

```json
{
  "risk_level": "R0",
  "fast_lane": true,
  "scope_check": { "status": "PASS" },
  "runtime_files_changed": { "status": "PASS", "value": false },
  "dependency_files_changed": { "status": "PASS", "value": false },
  "managed_integrity": { "status": "PASS" },
  "build": { "status": "NOT_APPLICABLE" },
  "analyzer": { "status": "NOT_APPLICABLE" },
  "tests": { "status": "NOT_APPLICABLE" },
  "ui_capture": { "status": "NOT_APPLICABLE" },
  "output_qa": {"status": "NOT_APPLICABLE"},
  "audit": {"status": "NOT_APPLICABLE", "auditMode": "NONE"}
}
```

For R0, the Auditor is not invoked by default. If implementation or evidence reveals runtime impact, set `R0_FAST_LANE_INVALIDATED: true`, reclassify, and route to the appropriate audit mode.

## 7. Auditor: conditional review with rejection authority

The RPA Auditor is invoked only when the selected mode is `LIGHT` or `FULL`, or when a `NONE` route escalates. Start from the approved plan, audit reason, diff, changed files, Developer evidence, and the applicable validation summary. For an escalated R0, independently verify the classification and diff, then answer:

1. Is this genuinely non-behavioral?
2. Did only approved files change?
3. Could the change alter runtime, deployment, dependencies, interfaces, safety, or operations?
4. Is the diff consistent with the requirement?
5. Did the Developer incorrectly mark anything `NOT_APPLICABLE` that was actually relevant?
6. Is documentation handling correct?
7. Did managed integrity remain valid?

If an escalated R0 is satisfied, return `PASS` with:

```text
R0_FAST_LANE_VALIDATED: true
```

Do not perform broad repository rediscovery, full XAML review, dependency investigation, build reproduction, full Workflow Analyzer, functional test reproduction, or UI inspection unless evidence indicates the R0 classification may be incorrect.

### Auditor rejection

If the Auditor identifies behavioral impact, the Fast Lane never overrides its independent judgment:

```text
VERDICT: REWORK
R0_FAST_LANE_VALID: false
RECOMMENDED_RISK: R1 | R2 | R3
REASON:
...
```

The task then returns through the normal workflow.

## 8. Documentation behavior for R0

Use the existing `NONE | CONTEXT_ONLY | HUMAN_DOCS` system from `documentation.instructions.md` unchanged. A documentation file being edited does not automatically require the Documentation Agent:

- a typo/wording fix in `README.md` with no material meaning change is normally `DOCUMENTATION_IMPACT: NONE`;
- when the R0 change itself directly and completely edits the target human document, is localized, and needs no cross-document synchronization, set `DOCUMENTATION_AGENT_REQUIRED: false` even if the final impact is `HUMAN_DOCS`; Coordinator/Developer evidence verifies this decision, and an invoked Auditor independently verifies it when `AUDIT_MODE` is `LIGHT` or `FULL`;
- do not invoke the Documentation Agent merely to review a one-line documentation edit.

## 9. AGENTS.md behavior for R0

Do not update `AGENTS.md` for ordinary R0 changes (typo fix, formatting, comments, wording cleanup, grammar improvement). Only update it if stable agent-relevant context actually changes; if it does, reconsider whether the task should remain R0 or become `CONTEXT_ONLY`/higher risk.

## 10. Graphify and R0

Graphify architecture, scripts, refresh behavior, and caching are not redesigned for this Fast Lane. The Coordinator-owned preflight (`Test-ManagedFileIntegrity.ps1` plus `Refresh-BotGraph.ps1 -Mode Update`) remains mandatory for every risk level, but its successful evidence is passed to the Developer and, when `AUDIT_MODE` is `LIGHT` or `FULL`, to the Auditor rather than repeated at each handoff. A final source-state graph/integrity result is required for completion; when an Auditor is invoked, it consumes that result and it may be reused after Auditor PASS when fingerprints are unchanged.

What may be skipped for an eligible R0 change is task-level Graphify **discovery/query** work (`Query-BotGraph.ps1` broad relationship lookups for Impact Set discovery), only when every changed file is provably outside executable/project/dependency/graph-relevant structure (for example README wording, Markdown formatting, non-runtime documentation, a comments-only file):

```text
GRAPHIFY_REQUIRED: false
REASON:
Non-executable documentation-only R0 change.
```

Do not skip Graphify discovery if the change affects project structure, executable files, workflows, dependencies, or graph-relevant relationships. Never weaken Graphify requirements for R1–R3.

## 11. Evidence fields

Record in the change evidence:

```text
RISK_LEVEL: R0
R0_FAST_LANE_ELIGIBLE: true | false
R0_FAST_LANE_USED: true | false
```

When an Auditor is invoked for a Fast Lane change, its successful result includes `R0_FAST_LANE_VALIDATED: true`. A no-audit R0 completion has no Auditor marker. An invalidated Fast Lane records `R0_FAST_LANE_INVALIDATED: true` with reason and recommended risk instead.

# R1 Light Lane

## 12. What R1 means

> A localized, low-risk change that may affect runtime behavior but has a narrow, well-understood impact and limited regression surface.

R1 is **not** non-behavioral and never receives R0-level validation skipping. Applicable gates stay required; only discovery, planning, and independent review routing are narrowed.

## 13. R1 no-audit eligibility

Set `R1_NO_AUDIT_ELIGIBLE: true` only when every condition below is true. Otherwise set it to `false` and invoke at least a Light Auditor:

- no `project.json` change;
- no dependency change;
- no shared workflow/component change;
- no public workflow argument/interface change;
- no Config semantics change;
- no REFramework state-machine architecture change;
- no retry behavior change;
- no transaction semantics change;
- no `BusinessRuleException`/`SystemException` semantics change;
- no queue behavior change;
- no database write behavior change;
- no external-system write that introduces material risk;
- no credential/security-sensitive change;
- no Production configuration or environment change;
- no managed Dev Kit core modification outside approved scope;
- no unexpected changed files;
- all modified files are inside the approved Impact Set;
- direct callers/consumers are known and unchanged where required;
- Developer validation evidence is complete and current;
- no unresolved assumptions;
- no validation warnings requiring engineering judgment.

An eligible R1 no-audit route uses `AUDIT_MODE: NONE` only with the stricter Developer gate and self-review below. A non-eligible R1 defaults to `AUDIT_MODE: LIGHT`; use `FULL` for a full-audit trigger.

Typical R1 examples: a localized mapping/lookup-table correction; a simple Config adjustment with clearly limited impact; a small isolated condition correction; low-risk internal workflow logic that does not cross workflow boundaries; a localized argument-handling fix; a small non-critical calculation; a low-impact retry/timeout adjustment with clearly isolated scope.

Classification is based on impact, not the number of changed lines.

## 13. Explicit exclusions (never R1)

Architecture changes; broadly reused/common workflows; dependency changes with significant project impact; browser/UI selector changes with material operational risk; new application interactions; new external interfaces; major business-rule changes; email workflow redesign; significant Excel/output behavior change; file lifecycle changes; Orchestrator queues/assets/connections; database writes; external writes; credentials/secrets; security-sensitive logic; Production resources; REFramework transaction architecture; exception/retry logic with broad operational impact; deployment behavior; critical monitoring/logging contracts. An isolated captured click/type/selector correction can remain R1 when interfaces, dependencies, architecture, security, and cross-component contracts are unchanged.

When uncertain, escalate risk rather than defaulting to R1.

## 14. Coordinator: R1 eligibility check and targeted plan

`risk_level: R1` alone is never permission to use a no-audit or Light route. Record, in the Change Plan:

```text
RISK_LEVEL: R1
R1_LIGHT_LANE_ELIGIBLE: true | false
R1_LIGHT_LANE_REASON:
<concise factual justification>
R1_NO_AUDIT_ELIGIBLE: true | false
AUDIT_MODE: NONE | LIGHT | FULL
AUDIT_REASON:
```

If uncertainty exists, set `R1_LIGHT_LANE_ELIGIBLE: false`, `R1_NO_AUDIT_ELIGIBLE: false`, and use `LIGHT` or `FULL` audit routing.

When eligible, replace the full Executable Change Plan with a targeted plan — lighter than R2, more complete than R0 — and skip broad architectural discovery:

```text
change_id:
risk_level: R1
r1_light_lane:
  eligible: true
  reason: ...
objective:
scope:
  modify:
  verify:
  do_not_modify:
impact_set:
  direct:
  immediate_dependencies:
runtime_behavior_changed: true
audit_mode: NONE | LIGHT | FULL
audit_reason: <factual reason>
r1_no_audit_eligible: true | false
dependencies:
  changed: false
ui:
  affected: false
outputs:
  affected: false
validation:
  build_required:
  targeted_tests:
  analyzer_required:
  output_qa_required:
  ui_validation_required:
  developer_self_review_required: true when audit_mode is NONE for behavioral R1
documentation:
  impact: NONE | CONTEXT_ONLY | HUMAN_DOCS
  candidate_documents:
evidence_required:
```

## 15. R1 human approval

Human approval remains mandatory. Present the intended change, exact affected scope, R1 classification, Light Lane eligibility, expected runtime impact, and the validation that will still run, for example:

```text
Risk: R1
Audit mode: NONE or LIGHT
Affected scope: <workflow/config path>
Runtime impact: <localized behavior only>
Build: Required
Targeted test: Required
Independent audit: Required for LIGHT; skipped only when every no-audit condition passes
Broad regression: Not required unless implementation expands scope
```

## 16. Developer: R1 abbreviated procedure

```text
Receive approved targeted plan
  → verify listed source
  → verify immediate dependency closure
  → implement
  → run targeted applicable validation
  → produce evidence
```

Do not routinely perform broad repository rediscovery, full architecture analysis, unrelated workflow inspection, unrelated `.ai/context` loading, broad regression investigation, or new solution-option generation. Verify the targeted plan; do not expand scope without evidence.

### Developer invalidation

If implementation reveals wider impact (a shared workflow is unexpectedly affected, a dependency change becomes required, an external interface changes, UI interaction becomes necessary, architecture impact is discovered, more workflows are affected than planned, or the regression surface is broader than expected), stop using the Light Lane immediately:

```text
R1_LIGHT_LANE_INVALIDATED: true
Reason:
<what was discovered>
Recommended risk:
R2 | R3
Required workflow:
NORMAL | DEEP
```

## 17. R1 validation strategy

R1 does not skip validation because it is low risk; validation is targeted instead of broad. When `AUDIT_MODE: NONE`, the Developer must additionally satisfy:

- diagnostics = executed `PASS`, valid matching-state `REUSED`, or deterministic policy-authorized `SKIPPED` for an eligible localized R1 with complete change facts; any uncertainty or safety trigger requires execution;
- dependency restore = executed `PASS` or valid fingerprint-matched `REUSED`;
- `Build: REQUIRED` where executable logic changed;
- `uip rpa build = PASS`;
- `Targeted test: REQUIRED` where a relevant test exists and must pass;
- Workflow Analyzer runs when applicable to changed executable artifacts;
- dependency restore reuses a valid state where possible, and restores again if changed or uncertain;
- UI validation only if UI is affected;
- output QA only if output behavior is affected;
- Documentation Agent only according to `NONE | CONTEXT_ONLY | HUMAN_DOCS`;
- managed-file integrity is current;
- final source fingerprint is captured and shared by deterministic gates;
- changed files are contained by the approved Impact Set;
- no unexpected interface, dependency, or Config changes;
- `DEVELOPER_SELF_REVIEW = PASS` and `ESCALATE_TO_AUDITOR = false`.

A build PASS alone is insufficient. The fixed self-review asks:

1. Does the implementation satisfy every acceptance criterion?
2. Did I change only files inside the approved Impact Set?
3. Did any workflow argument/interface change?
4. Did retry, exception, transaction, queue, Config, dependency, security, or Production behavior change unexpectedly?
5. Are all deterministic validation results current for the final source fingerprint?
6. Did required functional/output/UI validation pass?
7. Is there any remaining uncertainty that would benefit from independent review?

An unexpected YES to question 3 or 4, or YES to question 7, sets `ESCALATE_TO_AUDITOR: true`.

For `AUDIT_MODE: NONE`, the Developer records actual-diff verification, confirms all changed files are inside the approved Impact Set, confirms no unexpected shared/interface/Config/dependency/risk change occurred, and supplies the completion evidence. No independent Auditor result is required. For `AUDIT_MODE: LIGHT` or `FULL`, the Auditor independently verifies the actual diff, approved Impact Set, unexpected-change detection, and risk classification.

## 18. R1 regression scope

R1 validates the changed component, its direct caller/consumer, the directly affected test, and the relevant output/input contract — not the entire bot:

```text
Changed workflow → direct caller → direct test
```

rather than:

```text
Changed workflow → entire repository
```

Broaden only when evidence indicates wider impact.

## 19. Auditor: R1 targeted review

When `AUDIT_MODE: LIGHT`, use the same RPA Auditor; no separate Light Auditor exists. Start from the Change Contract, targeted Change Plan, audit reason, R1 eligibility result, diff, Developer evidence, validation summary, changed files, and immediate impact closure. Answer:

1. Was R1 classification justified?
2. Is the change actually localized?
3. Was immediate impact fully captured?
4. Does the implementation satisfy the requirement?
5. Were applicable build/tests executed?
6. Are any required checks incorrectly marked `NOT_APPLICABLE`?
7. Is regression risk genuinely limited?
8. Is documentation classification correct?

Do not automatically rediscover the entire project, inspect unrelated workflows, rerun successful deterministic checks, perform broad documentation review, or analyze unrelated application/resource context. Broaden only when evidence is incomplete, unexpected files changed, implementation deviates from plan, validation is suspicious, or impact looks wider than R1 permits.

### Auditor rejection

```text
VERDICT: REWORK
R1_LIGHT_LANE_VALID: false
RECOMMENDED_RISK: R2 | R3
REASON:
...
```

The task then continues through the appropriate normal/deep workflow.

## 20. Documentation behavior for R1

Use the existing `NONE | CONTEXT_ONLY | HUMAN_DOCS` system from `documentation.instructions.md` unchanged. R1 normally avoids the Documentation Agent when `DOCUMENTATION_IMPACT: NONE`. For `CONTEXT_ONLY`, update `AGENTS.md` only when stable agent-facing facts changed; do not invoke the Documentation Agent by default. For `HUMAN_DOCS`, run the Documentation Agent — the Light Lane never bypasses genuinely required human documentation.

## 21. Graphify and R1

Graphify architecture, scripts, refresh behavior, and caching are not redesigned for this lane. The Coordinator checks `project.json` first, always runs managed integrity, and runs cache-first `Refresh-BotGraph.ps1 -Mode Update` for existing bots. New bots defer graph discovery until the stable finalization step.

For an eligible R1 change with an already-narrow approved Impact Set, avoid unnecessary broad `Query-BotGraph.ps1` relationship lookups and use the existing Impact Set/graph context intelligently instead of re-querying broadly. Do not add Graphify caching, modify refresh architecture, introduce incremental Graphify, or weaken integrity controls. Report:

```text
GRAPHIFY_ARCHITECTURE_CHANGED: NO
```

## 22. R1 evidence fields

Record in the change evidence:

```text
RISK_LEVEL: R1
R1_LIGHT_LANE_ELIGIBLE: true | false
R1_LIGHT_LANE_USED: true | false
R1_LIGHT_LANE_INVALIDATED: true | false
R1_NO_AUDIT_ELIGIBLE: true | false
AUDIT_MODE: NONE | LIGHT | FULL
AUDIT_REASON:
DEVELOPER_SELF_REVIEW: PASS / FAIL / NOT_APPLICABLE
ESCALATE_TO_AUDITOR: true | false
```

Auditor result for a successful Light Lane change includes `R1_LIGHT_LANE_VALID: true`. A no-audit R1 result includes `DEVELOPER_SELF_REVIEW: PASS` and `ESCALATE_TO_AUDITOR: false`; it has no Auditor verdict. An invalidated Light Lane records `R1_LIGHT_LANE_INVALIDATED: true` (or Auditor `R1_LIGHT_LANE_VALID: false`) with reason and recommended risk instead.

## 23. Representative R1 scenarios

| Scenario | Expected classification |
| --- | --- |
| Localized mapping/lookup-table correction | R1; `NONE` only when every no-audit condition passes, otherwise Light Auditor |
| Small isolated condition fix with clearly local impact | R1, Light Lane |
| Isolated selector or normal browser interaction with complete capture evidence | R1 when interfaces, dependencies, architecture, security, and cross-component contracts are unchanged; otherwise R2 |
| Config value with broader runtime impact | Escalate to R2 |
| Shared workflow unexpectedly affected during implementation | Developer invalidates R1 → R2 |
| Auditor detects broader downstream impact than reported | Light Auditor returns `ESCALATE_TO_FULL_AUDIT` or reclassifies → Full audit |
| Dependency change becomes required | Usually escalate to R2 |

## 24. R2 Normal Lane and R3 Deep Lane

R2 and R3 are not abbreviated. R2 keeps the full Coordinator → approval → Developer → applicable validation → documentation routing → normal Auditor workflow with standard planning, validation, and audit depth. R3 receives deeper impact analysis, broader regression consideration, stronger evidence, and broader Auditor review; it is never optimized for speed at the expense of assurance. Neither lane is reduced by the introduction of the R1 Light Lane.

## 25. Unified risk/lane matrix

| Risk | Lane | Planning | Validation | Auditor |
| --- | --- | --- | --- | --- |
| R0 | Fast | Minimal | Minimal applicable | Lightweight |
| R1 | Light/None | Targeted | Targeted applicable | Self-review when None; targeted when Light |
| R2 | Normal | Standard | Standard | Normal |
| R3 | Deep | Expanded | Expanded | Deep |

| Activity | R0 | R1 | R2 | R3 |
| --- | --- | --- | --- | --- |
| Human approval | Yes | Yes | Yes | Yes |
| Broad discovery | No | Usually no | As needed | More likely |
| Build | N/A | If executable changed | If applicable | If applicable |
| Targeted tests | N/A | Yes when applicable | Yes | Yes |
| Broad regression | No | Usually no | As needed | More likely |
| Documentation Agent | Rare | Conditional | Conditional | Conditional / more likely |
| Auditor scope | Lightweight | Targeted | Standard | Deep |
| Independent audit | No by default | No when eligible; otherwise Yes | Yes | Yes |
