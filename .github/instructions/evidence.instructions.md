---
description: Evidence and completion rules for autonomous RPA development tasks.
applyTo: "**"
---
# Evidence rules

A completion claim must be backed by evidence.

For a Dev Kit payload import or new-bot bootstrap, record:

- payload version and `.rpa-ai/kit-manifest.json` integrity result;
- added, preserved, upgraded, overwritten, and conflicting paths;
- intake files considered and any formats that could not be extracted;
- Process/REFramework, target framework, expression language, and template decision;
- official UiPath CLI command family, template ID or Official package/version, exit status, generated files, structural checks, and collision-free transfer;
- confirmation that bot-owned intake/context/evidence was preserved.

Minimum evidence for a behavioral code change:

- requirement/acceptance-criteria summary,
- persisted execution state with task type, wall-clock start, current/final stage, elapsed seconds, all applicable stage durations, repair-loop count, and bottleneck;
- total wall-clock, active-execution, explicit user-wait seconds, stage intervals, command durations/exit/timeout/output evidence, and preserved prior run history;
- execution-state byte size, abnormal-size warning, largest state sections/evidence artifacts, and command-output path/hash/size with only a bounded inline preview;
- approved Executable Change Plan and R0-R3 risk classification,
- Coordinator preflight (`PREFLIGHT_STATUS`, `MANAGED_CORE_STATUS`, `GRAPH_STATE`, source fingerprint) and structured Impact Set,
- change classification,
- impacted files/workflows,
- source-control diff review,
- browser UI target/selector discovery evidence when a browser interaction changed,
- validation command(s) and exit status,
- compact deterministic validation summary and dependency-state reuse decision when applicable,
- shared source-fingerprint schema/version and executable/documentation/graph-configuration fingerprints plus validation timestamp for every deterministic gate,
- Developer Audit Packet mapping acceptance criteria to changed files and direct dependencies,
- risk-based diagnostics decision (`riskClassification`, required/executed flags, reason, relevant change facts, and duration) plus analyzer/build diagnostics when applicable,
- relevant test or Development execution result when available,
- Developer documentation confirmation and Documentation Agent result when `HUMAN_DOCS` applies; evidence-based `NONE` or `CONTEXT_ONLY` routing when the agent is not invoked,
- Outlook capability result and environment-aware email validation when email behavior is relevant,
- output artifact data/readability/formatting evidence when the process creates or changes a business file,
- audit mode/reason and the independent Auditor verdict when invoked, or the Developer self-review when audit mode is `NONE`,
- assumptions and residual risks.

For browser UI interactions, evidence must prove the **ordering and completeness** of the capture gate:

- `UI_CAPTURE_REQUIRED: true`
- `BROWSER_OPENED_OR_ATTACHED: true`
- required target inventory
- captured/proven target count
- one entry per target with screen/page, business action, capture route, descriptor/selector summary, and proof result
- `UI_CAPTURE_COMPLETE: true` before implementation is reported

For UiPath implementations, the evidence must include UiPath target/descriptor capture; Python-only DOM locator evidence is insufficient. Do not persist credentials, tokens, sensitive page content, or unnecessary screenshots.

For output artifacts, evidence must prove more than file creation:

- `OUTPUT_QA_REQUIRED: true`
- artifact name/path/type
- execution step that generated it
- schema/content checks and representative record/range/section checks
- readability/value-format checks
- presentation checks for human-readable formats
- for Excel: relevant header/width/number-date/ID/clipping/formula-error/template-contract checks
- `OUTPUT_QA_COMPLETE: true`

Do not copy full sensitive output datasets into evidence. Summarize what was checked.

For email/Outlook behavior, do not claim execution, sending, or delivery without actual Development evidence. When `OUTLOOK_ACTIVITY_AVAILABLE = false`, record the independently validated email components and the local execution limitation.

For a valid **GENERATED_SCAFFOLD_ONLY** change, normal technical validation evidence is replaced by scaffold provenance evidence:

- generator: UiPath Studio or official UiPath CLI,
- generation command when applicable,
- generated file list,
- confirmation that no generated behavior was edited after creation,
- Auditor verification that the exemption applies.

Write generated evidence under `.ai/evidence/` when the task needs persistent output.

Do not fabricate test results. If an applicable gate cannot run, mark it `NOT_RUN` with the reason and let the Auditor decide whether the task is BLOCKED. Do not mark scaffold-exempt gates as passed; mark them `EXEMPT_GENERATED_SCAFFOLD`.

## Handoff and freshness evidence

The Developer returns one concise Audit Packet for the Auditor. It must contain:

```json
{
	"risk": "R1",
	"requirementMapping": [],
	"changedFiles": [],
	"directDependenciesReviewed": [],
	"impactSetDelta": [],
	"interfacesChanged": false,
	"dependenciesChanged": false,
	"configChanged": false,
	"auditMode": "NONE | LIGHT | FULL",
	"auditReason": "<factual reason>",
	"r1NoAuditEligible": true,
	"developerSelfReview": "PASS | FAIL | NOT_APPLICABLE",
	"escalateToAuditor": false,
	"sourceFingerprint": "<fingerprint>",
	"dependencyFingerprint": "<fingerprint>",
	"validation": {
		"restore": { "status": "PASS | REUSED", "sourceFingerprint": "<fingerprint>" },
		"getErrors": { "status": "PASS", "sourceFingerprint": "<fingerprint>" },
		"build": { "status": "PASS", "sourceFingerprint": "<fingerprint>" },
		"functionalTest": { "status": "PASS | NOT_RUN" }
	},
	"remainingLimitations": [],
	"deterministicReruns": []
}
```

When invoked, the Auditor must consume current, trustworthy deterministic evidence and focus independent review on requirements, scope, business semantics, REFramework correctness, safety, and risk. A deterministic gate may be rerun only for a documented trigger: missing/malformed/stale evidence, source or dependency fingerprint mismatch, unexpected files, configuration/dependency change, material plan deviation, inconsistent results, or risk-required independent validation. `AUDIT_MODE: NONE` requires the Developer's stricter gate and self-review; it does not create an Auditor verdict.

## Dependency setup evidence

For behavioral changes record `DEPENDENCY_SETUP_REQUIRED`, capability-to-dependency mapping, existing/restored/new status, version/source when known, restore/install/verification action and result, changed project/manifest files, and `DEPENDENCY_SETUP_COMPLETE`.

## R0 Fast Lane evidence

For a change proposed under the R0 Fast Lane, record `RISK_LEVEL: R0`, `AUDIT_MODE: NONE`, `AUDIT_REASON`, `R0_FAST_LANE_ELIGIBLE`, and the factual `R0_FAST_LANE_REASON`. Record `R0_FAST_LANE_USED: true | false` and the minimal validation summary from `.github/instructions/risk-routing.instructions.md`, marking objectively irrelevant checks `NOT_APPLICABLE` rather than `PASS`. If runtime impact or another audit trigger appears, record `R0_FAST_LANE_INVALIDATED: true` with the reason and recommended risk instead of a Fast Lane result. A successful R0 route has no Auditor verdict unless escalated.

## R1 Light Lane evidence

For a change proposed under the R1 Light Lane, record `RISK_LEVEL: R1`, `AUDIT_MODE`, `AUDIT_REASON`, `R1_LIGHT_LANE_ELIGIBLE`, `R1_NO_AUDIT_ELIGIBLE`, and the factual eligibility reasons. Record `R1_LIGHT_LANE_USED: true | false`, the targeted validation summary, and `DEVELOPER_SELF_REVIEW`/`ESCALATE_TO_AUDITOR` when `AUDIT_MODE: NONE`; apply build/targeted-test/analyzer/UI/output gates rather than skipping them. If the Developer or Auditor discovers wider impact than the approved targeted plan, record `R1_LIGHT_LANE_INVALIDATED: true` with the reason and recommended risk (`R2` or `R3`) instead of a Light Lane result. A successful Light audit records `R1_LIGHT_LANE_VALID: true`; a successful no-audit route records the self-review instead and has no Auditor verdict.

