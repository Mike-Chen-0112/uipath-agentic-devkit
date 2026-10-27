# RPA Change Evidence

<!-- markdownlint-disable MD060 -->

- Timestamp:
- Request:
- Outcome: PASS / REWORK / BLOCKED
- Risk level: R0 / R1 / R2 / R3
- Audit mode: NONE / LIGHT / FULL
- Audit reason:
- Change classification: BEHAVIORAL_CHANGE / GENERATED_SCAFFOLD_ONLY / NON_BEHAVIORAL_R0
- User approved proposed Development change: true / false
- Approval timestamp / reference:

## Execution timing evidence

- Execution state path: `.ai/evidence/execution-state.json`
- Task type: `new_bot` / `modification`
- Total wall seconds:
- Active execution seconds:
- Explicit user-wait seconds:
- Repair loops / maximum: `0-3` / `3`
- Bottleneck stage:

| Stage | Started | Ended | Duration seconds | Status |
| --- | --- | --- | --- | --- |
| coordinator |  |  |  |  |
| coordinator_handoff |  |  |  |  |
| scaffolding |  |  |  |  |
| developer |  |  |  |  |
| validation |  |  |  |  |
| auditor |  |  |  |  |
| documentation |  |  |  |  |
| graph |  |  |  |  |
| finalization |  |  |  |  |

- Developer lifecycle phases: request-to-first-tool / state / map / graph-context / context-build / source / implementation / local-validation / evidence / state-write / handoff
- Developer timing coverage / unattributed seconds:
- Developer context profile path / bytes / estimated tokens / raw XAML count / full Graphify included:
- Developer context package path / scoped-map bytes / graph-summary bytes / workflows represented:
- Fast context used / fallback / fallback reasons / source expansions:
- Developer validation result / deterministic-validation duration:
- Developer finalization result / evidence / handoff paths:
- Finalization fingerprint / evidence / handoff / state-write / total timings:
- Atomic Developer state-write count / recovery status:
- Host/model boundaries marked `NOT_INSTRUMENTABLE`:
- Command evidence path: `.ai/evidence/execution-state.json.commands`
- Command durations/status/timeouts:
- Pause/resume reasons:

## Change Contract

### Business intent

### Acceptance criteria

## R0 Fast Lane evidence

Complete this section only when the change was proposed/used under the R0 Fast Lane; otherwise write N/A.

- R0_FAST_LANE_ELIGIBLE: true / false
- R0_FAST_LANE_REASON:
- R0_FAST_LANE_USED: true / false / N/A
- R0_FAST_LANE_INVALIDATED: true / false (reason and recommended risk if true)
- R0_FAST_LANE_VALIDATED: true / false / N/A (Auditor result when invoked)

## R1 Light Lane evidence

Complete this section only when the change was proposed/used under the R1 Light Lane; otherwise write N/A.

- R1_LIGHT_LANE_ELIGIBLE: true / false
- R1_LIGHT_LANE_REASON:
- R1_LIGHT_LANE_USED: true / false / N/A
- R1_LIGHT_LANE_INVALIDATED: true / false (reason and recommended risk if true)
- R1_LIGHT_LANE_VALID: true / false / N/A (Auditor result when invoked)
- R1_NO_AUDIT_ELIGIBLE: true / false / N/A
- DEVELOPER_SELF_REVIEW: PASS / FAIL / N/A
- ESCALATE_TO_AUDITOR: true / false / N/A

## Changed files

## Dev Kit core and graph evidence

- Coordinator preflight: `PREFLIGHT_STATUS`, `MANAGED_CORE_STATUS`, executable source fingerprint schema/version:
- Initial bot-local graph state: `PASS` / `REUSED`, executable source fingerprint, graph configuration fingerprint, timestamp, Graphify version:
- Managed Dev Kit files changed: none / list and reviewed payload-upgrade reason
- Dev Kit feedback entry: none / `.ai/feedback/dev-kit-improvements.md`
- Final bot-local graph state: `PASS` / `REUSED`, executable source fingerprint, graph configuration fingerprint, timestamp, Graphify version:
- Documentation fingerprint:
- Final managed-file integrity: `PASS` / `REUSED`, fingerprint, timestamp, rerun reason if applicable:

## Dependency setup evidence

Complete this section for every `BEHAVIORAL_CHANGE`.

- DEPENDENCY_SETUP_REQUIRED: true / false
- DEPENDENCY_SETUP_COMPLETE: true / false / N/A

| Required capability | Dependency / prerequisite | Existing / restored / newly installed | Version / constraint | Source / feed / mechanism | Install / restore / verification evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |

For UiPath packages, use supported package tooling rather than manually editing `project.json` dependency entries. Record machine prerequisites that were verified even when no project file changed. Do not record credentials/tokens.

## Browser UI capture evidence

Complete this section when browser UI interaction is added or changed.

- UI_CAPTURE_REQUIRED: true / false
- BROWSER_OPENED_OR_ATTACHED: true / false / N/A
- Required targets:
- Captured/proven targets:
- Target Registry path / schema / bytes:
- Targets required / registry hits / misses:
- Reuse attempted / succeeded / failed / failure reason:
- Target ID / logical name / Web or Native context:
- Strategy / selector-quality score and class / anchor / fallback:
- Validation status / level (`STATIC`, `LIVE`, `UNSUPPORTED`) / method:
- Discovery attempts / duplicate attempts prevented / unresolved targets:
- Lookup / discovery / validation / registry-write / total resolution milliseconds:
- Referenced screenshot/artifact path / hash / bytes (never inline):
- UI_CAPTURE_COMPLETE: true / false / N/A
- Implementation route: UiPath UIA / Python implementation / N/A

| Business action | Target name | Page / screen | Capture route | Target / descriptor summary | Safe live proof | Result |
| --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |

For a UiPath workflow, the capture route must include UiPath UI Automation/Object Repository evidence. Python-only DOM evidence does not satisfy the capture gate. Do not record credentials, tokens, or sensitive page content.

## Output artifact QA evidence

Complete this section when the process creates, exports, downloads, transforms, or updates a business output file.

- OUTPUT_QA_REQUIRED: true / false
- Output artifact(s):
- Actual process-generated file inspected: true / false / N/A
- Data/schema checks:
- Representative records/ranges/sections checked:
- Readability/value-format checks:
- Presentation/layout checks (human-readable formats):
- OUTPUT_QA_COMPLETE: true / false / N/A

For Excel, summarize applicable header/width/wrapping/number-date/ID/clipping/formula-error/template-contract checks. Do not copy full sensitive output data into evidence.

## Outlook capability and email testing evidence

Complete this section when email or Outlook behavior is added or changed.

- OUTLOOK_CAPABILITY_CHECK_REQUIRED: true / false
- OUTLOOK_ACTIVITY_AVAILABLE: true / false / NOT_RUN
- Capability result: `.rpa-ai/local/outlook-capability.json` / reason
- Email test path: Outlook end-to-end / independent component validation
- Independently validated components: Subject, To, CC, BCC, HTML/body, rendered layout, dynamic values, attachments, send conditions, surrounding logic
- Outlook execution/send/delivery claim: tested / not tested
- Development-only test mechanisms kept out of production: true / false / N/A

## Documentation impact evidence

- Planned documentation impact: NONE / CONTEXT_ONLY / HUMAN_DOCS
- Final `DOCUMENTATION_CONFIRMATION`: NONE / CONTEXT_ONLY / HUMAN_DOCS
- Reason and affected topics:
- `CONTEXT_UPDATE_REQUIRED`: true / false / N/A
- `AGENTS.md` update: updated / not required / N/A
- Candidate documents:
- Documentation Agent result: UPDATED / REWORK / NOT_INVOKED
- Changed documentation files/sections:
- Verified against implementation and evidence: true / false / N/A

## File journey graph evidence

Complete this section when the process downloads, copies, reads, edits, renames, archives, uploads, or deletes files.

- FILE_JOURNEY_REQUIRED: true / false
- FILE_JOURNEY_PATH: `.ai/context/file-journey.md` / N/A
- FILE_JOURNEY_CAPABILITIES: download / copy / read / edit / rename / archive / upload / delete (applicable values only)
- Changed artifact nodes/edges:
- Source/configuration cross-check:
- Sensitive-content check:
- FILE_JOURNEY_COMPLETE: true / false / N/A

## Generated scaffold provenance

Complete this section only for `GENERATED_SCAFFOLD_ONLY`.

- Generator: UiPath Studio / official UiPath CLI
- CLI command family (if applicable):
- Project type: Process / REFramework / other
- Target framework: Windows / Portable / Legacy
- Expression language: VisualBasic / CSharp
- Template ID or package/version/source:
- Generated files:
- Staging and collision checks:
- Bot intake preserved: true / false / N/A
- Confirmation that generated behavior was not edited after generation:

## Validation

| Gate | Command / evidence | Status | Notes |
| --- | --- | --- | --- |
| project-json |  | PASS / FAIL / NOT_RUN / NOT_APPLICABLE / EXEMPT_GENERATED_SCAFFOLD |  |
| r0-eligibility-check |  | PASS / FAIL / NOT_APPLICABLE |  |
| managed-core-integrity |  |  |  |
| r0-scope-diff-verification |  | PASS / FAIL / NOT_APPLICABLE |  |
| graph-readiness |  |  |  |
| payload-integrity |  |  |  |
| project-scaffold |  |  |  |
| predevelopment-dependencies |  |  |  |
| restore |  |  |  |
| build |  |  |  |
| browser-ui-target |  |  |  |
| analyzer |  |  |  |
| diagnostics |  |  |  |
| functional-test |  |  |  |
| documentation-handoff |  | PASS / FAIL / NOT_RUN |  |
| outlook-capability |  | PASS / FAIL / NOT_RUN |  |
| output-artifact-quality |  |  |  |
| generated-scaffold-provenance |  |  |  |
| audit-routing |  |  |  |
| audit |  | PASS / REWORK / ESCALATE_TO_FULL_AUDIT / BLOCKED / NOT_INVOKED |  |

Diagnostics decision: `riskClassification`, `diagnosticsRequired`, `diagnosticsExecuted`, `diagnosticsDecisionReason`, relevant change facts, and duration.

Performance evidence: validation phase timings, role sub-timings where measurable, execution-state byte size/warning, and largest state/evidence references. Keep full command output and large immutable artifacts at their recorded paths with hash/size; do not duplicate them inline.

Use `NOT_APPLICABLE` for a gate that is genuinely irrelevant to the change; do not report a skipped gate as `PASS`.

## Auditor verdict

Record the independent verdict only when `AUDIT_MODE` is `LIGHT` or `FULL`; otherwise record `NOT_INVOKED` and the Developer self-review result.

## Assumptions / residual risks

<!-- markdownlint-enable MD060 -->
