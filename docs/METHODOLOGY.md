# Methodology

## The core model

One distributable bot payload, four agents, an intake/context knowledge layer, official UiPath project scaffolding when needed, pre-development dependency setup, live UI discovery when needed, and deterministic validation when applicable.

```text
User + .ai/intake
 ↓
Coordinator ── reads ──> Intake + Bot Context + Knowledge Graph
 ↓
Solution Selection ──> 1-3 distinct options + recommendation
 ↓
One selected proposal + existing single development approval
 ↓
Developer ─── uses ───> official scaffold + dependency setup + UiPath Skills + uip CLI + live UI target discovery
 ↓
Documentation ────────> targeted verified documentation update or NO_DOCUMENTATION_CHANGE
 ↓
Audit routing ────────> NONE: Developer self-review | LIGHT/FULL: Auditor
 ↓
Coordinator
 ├─ PASS → Final result
 ├─ REWORK → Developer → Auditor
 └─ BLOCKED → Human decision
```

## Why four agents

### Coordinator = control plane

Owns business intent, acceptance criteria, orchestration and final status. It should not be the primary code editor.

### Developer = execution plane

Owns pre-development dependency setup, technical implementation, live UI target discovery, UiPath tooling, applicable validation and self-healing.

### Auditor = conditional independent quality gate

Owns independent verification when risk requires it and must not edit the implementation. R0 and eligible R1 work may complete after deterministic validation and Developer self-review without an Auditor invocation; R2/R3 and triggered escalations retain independent audit.

When invoked, independent review avoids the common failure mode where one model makes a change and then simply agrees with itself that the change is correct; eligible no-audit work instead requires the fixed Developer self-review and complete deterministic evidence gate.

### Documentation = verified human-facing record

RPA Documentation receives only the Developer's concise handoff first, then changed-file information, the approved Change Contract, and relevant evidence. It reads and edits only affected sections of the standard bot documents, or returns `NO_DOCUMENTATION_CHANGE` when the evidence supports that result.

## Standard bot documentation

Every bot payload provides a short root `README.md` and these detailed documents:

- `docs/Bot-Documentation.md` for the single ordered technical and operational record;
- `docs/Testing.md` for scenarios, expected behavior, environment limitations, and live-runtime requirements;
- `docs/CHANGELOG.md` for meaningful functional or architectural changes only.

These documents are preserve-owned so upgrades do not overwrite project documentation.

## Change Contract

Every request is normalized into:

1. Business intent.
2. Acceptance criteria.
3. Constraints.
4. Assumptions.
5. Impact set.
6. Required technical capabilities/dependencies and machine prerequisites implied by the process.
7. Required browser UI interactions, if any.
8. Output artifacts, expected schema/data, readability/formatting expectations, and downstream file-contract constraints, if any.
9. For a new bot: Process or REFramework, Windows or Portable, expression language, and trusted template selection.
10. Selected solution option and the reasons it fits the existing architecture.

## Distribution and bootstrap methodology

The central repository exports a bot payload from `distribution/payload-manifest.json`. The payload includes managed agent policy and preserve-only bot-owned templates. `.rpa-ai/kit-manifest.json` records the release version and hashes used by checked import and future upgrades.

When `project.json` is absent:

```text
READ ACCESSIBLE .ai/intake FILES
  ↓
RESOLVE PROCESS vs REFRAMEWORK + WINDOWS vs PORTABLE
  ↓
PROBE CURRENT uip rpa COMMAND SURFACE
  ↓
GENERATE OFFICIAL SCAFFOLD IN ISOLATED STAGING
  ↓
VERIFY project.json + WORKFLOWS + COLLISIONS
  ↓
TRANSFER TO BOT ROOT + RECORD PROVENANCE
  ↓
UNTOUCHED? GENERATED_SCAFFOLD_ONLY
EDIT BEHAVIOR? BEHAVIORAL_CHANGE
```

The payload makes the repository non-empty, so official scaffolding is generated in a sibling staging directory and copied only after collision checks. `project.json` and starter XAML are never hand-authored.

The Change Contract remains stable through Developer/Auditor handoffs.

## R0 Fast Lane

A provably non-behavioral R0 change (documentation wording, comments, formatting) may use an abbreviated branch instead of the full lifecycle above:

```text
Coordinator classifies R0 ──> R0_FAST_LANE_ELIGIBLE check
  eligible? concise plan ──> human approval ──> Developer abbreviated procedure
  not eligible/uncertain? normal R1-R3 workflow
```

The same four agents remain available; no separate Fast Lane agent exists. Human approval, managed-core integrity, deterministic validation, capability gates, and evidence stay mandatory. `AUDIT_MODE` is explicit: R0 defaults to `NONE`, eligible R1 may use `NONE`, other R1 defaults to `LIGHT`, R2 uses `LIGHT` or `FULL`, and R3 uses `FULL`. The Developer self-review or Auditor can invalidate no-audit routing at any time and fall back to the required audit mode. Full rules live in `.github/instructions/risk-routing.instructions.md`.

## Retrieval methodology

Use least-expensive context first:

1. `.ai/intake/` for new-bot business source material;
2. curated `.ai/context/` when present;
3. bot knowledge graph;
4. targeted repository search;
5. current source files for verification.

Avoid reading the entire bot unless impact cannot be determined otherwise.

## Pre-development dependency methodology

Every `BEHAVIORAL_CHANGE` sets `DEPENDENCY_SETUP_REQUIRED = true` immediately after impact retrieval/classification. The Developer must prepare the implementation environment before browser capture and before executable authoring.

Required order:

```text
Requirement + Impact Set
  ↓
Derive required capabilities
  ↓
Inventory current project dependencies / Python environment / machine prerequisites
  ↓
Restore already-declared UiPath dependencies
  ↓
Discover + install genuinely missing dependencies with supported tooling
  ↓
Verify activity/import/runtime availability
  ↓
DEPENDENCY_SETUP_COMPLETE = true
  ↓
Continue to UI capture (if needed) or authoring
```

For UiPath packages, the installed `uipath-rpa` skill/current CLI surface is authoritative. Use `uip rpa restore` for dependencies already declared in `project.json`; install new dependencies through `uip rpa packages install` or the compatible `uip rpa install-or-update-packages` surface exposed locally. Do not manually edit dependency entries when supported package tooling is available.

For Python, reuse the repository's existing environment and dependency-manifest/lock convention. For machine prerequisites, verify first and install only through approved Development-safe mechanisms within current permissions. If a required dependency cannot be resolved, return `BLOCKED_DEPENDENCY` before implementation.

See `DEPENDENCY-SETUP-PROTOCOL.md`.

## Browser UI capture-first methodology

When a change includes browser click, type, read, extract, navigation, submit, hover, upload/download-through-UI, or state checks, set `UI_CAPTURE_REQUIRED = true`. Source inspection alone is insufficient and UI authoring is forbidden until capture is complete.

Required order:

```text
Identify browser UI steps
  ↓
Resolve Development entry point
  ↓
Open/attach Development browser automatically
  ↓
Reach exact screen state
  ↓
Inventory ALL required targets
  ↓
Capture/configure targets with UiPath UIA (for UiPath deliverables)
  ↓
Safely prove every click/type/read/extract/state action
  ↓
UI_CAPTURE_COMPLETE = true
  ↓
Author/edit workflow against captured targets
```

For UiPath XAML/coded workflows, UiPath UI Automation/Object Repository capture is mandatory. Python/Playwright/Selenium may be used only as supplemental diagnostics; a DOM locator does not prove that UiPath can resolve the target. If the final implementation itself is intentionally Python, the same capture-first ordering applies using the project's live browser stack.

The installed `uipath-rpa` skill and installed UI Automation package guide own the concrete capture commands and selector mechanics. The agent must load those instructions before UIA work rather than inventing CLI syntax.

If live capture is genuinely impossible, return `BLOCKED_UI_CAPTURE`. Placeholder-selector mode is allowed only when explicitly requested/deferred by the user.

## Output artifact QA methodology

When the process creates, exports, downloads, transforms, or updates a business output file, set `OUTPUT_QA_REQUIRED = true`. After the safe Development execution produces the artifact, inspect the actual generated file before audit.

Required order:

```text
RUN SAFE DEVELOPMENT PATH
  ↓
LOCATE ACTUAL GENERATED ARTIFACT
  ↓
OPEN / READ / PARSE OUTPUT
  ↓
VERIFY SCHEMA + REPRESENTATIVE DATA
  ↓
VERIFY BUSINESS-READABLE VALUE REPRESENTATION
  ↓
HUMAN-READABLE FORMAT? ─ yes ─> VERIFY LAYOUT / FORMATTING
  ↓
OUTPUT_QA_COMPLETE = true
  ↓
AUDIT
```

For Excel, the baseline includes appropriate headers, widths, date/number formats, ID preservation, wrapping where needed, no `#####` clipping, and no visible formula errors, while preserving approved templates and downstream machine contracts. CSV/TSV is checked for encoding/delimiter/quoting/schema rather than cell styling. Human-readable PDF/Word/report outputs should be opened/rendered when tooling permits.

A file existence check is never sufficient. If the artifact is wrong, repair the automation/template and regenerate it; do not manually repair only the test file.

## Change classification and validation applicability

Before validation, classify the implementation:

### BEHAVIORAL_CHANGE

Any AI-authored or edited executable behavior, argument, dependency, selector, project wiring, configuration behavior, or Python/XAML logic.

Normal applicable validation is required.

### GENERATED_SCAFFOLD_ONLY

Only trusted template/scaffold files created by UiPath Studio or the official UiPath CLI are introduced, and they remain unmodified after generation.

For this class, restore/build/analyzer/diagnostics/functional execution are not run solely to “validate” the trusted generated template. Instead, the Developer records generator provenance; the Coordinator/Developer verify the exemption, and an invoked Auditor verifies it independently when the selected audit mode requires one.

If the agent edits the generated file afterward, the exemption ends immediately and the change becomes `BEHAVIORAL_CHANGE`.

## Development loop

```text
UNDERSTAND
  ↓
PROJECT EXISTS? ─ no ─> READ INTAKE → OFFICIAL SCAFFOLD → VERIFY + TRANSFER
  ↓
RETRIEVE / IMPACT ANALYSIS
  ↓
CLASSIFY CHANGE
  ↓
BEHAVIORAL_CHANGE? ─ yes ─> DEPENDENCY_SETUP_REQUIRED
                              -> INVENTORY CAPABILITIES / DEPENDENCIES
                              -> RESTORE / INSTALL / VERIFY
                              -> DEPENDENCY_SETUP_COMPLETE
  │
  no (trusted untouched scaffold)
  ↓
GENERATE SCAFFOLD + RECORD PROVENANCE

After dependency setup for a behavioral change:

BROWSER UI CHANGE? ─ yes ─> UI_CAPTURE_REQUIRED
                              -> OPEN/ATTACH LIVE BROWSER
                              -> CAPTURE + PROVE ALL TARGETS
                              -> UI_CAPTURE_COMPLETE
  │
  no
  ↓
PLAN
  ↓
IMPLEMENT
  ↓
RESTORE / BUILD / ANALYZE (as applicable)
  ↓
SAFE DEV TEST / RUN
  ↓
OUTPUT FILE? ─ yes ─> OUTPUT QA ─ fail ─> FIX + REGENERATE
  ↓
FAIL? ─ yes ─> DIAGNOSE → FIX → rerun relevant gate
  ↓
AUDIT
  ↓
REWORK? ─ yes ─> DEVELOPER → AUDIT
  │
  no
  ↓
PASS
```

For `GENERATED_SCAFFOLD_ONLY`, normal behavioral dependency/build/test gates are not invoked solely to validate untouched Studio/official-CLI template output; generation provenance is audited instead. If the scaffold is edited, it becomes `BEHAVIORAL_CHANGE` and the dependency-first lifecycle applies.

## Knowledge ownership

- Central repo owns methodology, payload inventory, agents, shared standards, graph contract, setup scripts, tests, and policy.
- The exported payload contains only bot-relevant managed files and preserve-only starter files.
- Each bot owns intake, derived context, graph output, evidence, UiPath source, and configuration.
- The graph is generated from each bot; the central repo is not updated when a new bot is onboarded.

## Future-proofing

Keep integrations behind stable roles/contracts:

- UiPath skills can evolve without rewriting company standards.
- Live UI discovery uses the installed UiPath command surface instead of hard-coding unsupported commands.
- For UiPath deliverables, UiPath UI Automation capture is mandatory; Python is only supplemental. For intentionally Python browser implementations, capture-first live DOM discovery applies.
- Graph provider can change without changing the Coordinator, Developer, Documentation, or Auditor responsibilities.
- Azure DevOps CI/CD can later consume the same validation policy.
- Additional agents should only be added when a distinct control boundary or specialist capability justifies them.
