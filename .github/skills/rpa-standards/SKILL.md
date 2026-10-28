---
name: rpa-standards
description: Centrally managed UiPath RPA engineering standards, REFramework conventions, environment boundaries, logging, exceptions, configuration, and autonomous-development completion rules.
---
# Shared RPA Engineering Standards

This skill contains the shared standards that accompany every RPA AI Dev Kit bot payload. Maintain it in the central Dev Kit and distribute it unchanged to bot repositories.

## Environment model

- Development server / Development Orchestrator: permitted for development and testing according to access policy.
- Production server / Production Orchestrator: prohibited to AI development agents.
- Production deployment and job execution are outside this Dev Kit's initial scope.

## Source control

- UiPath project source is stored in the organization's Azure DevOps project repositories.
- Make minimal, reviewable changes.
- Do not commit generated runtime logs, secrets, local package caches, or machine-specific paths.

## RPA architecture

### REFramework projects

Preserve the standard responsibilities unless an approved project variant says otherwise:

- **Init** — configuration, assets/credentials, application initialization.
- **Get Transaction Data** — transaction acquisition only.
- **Process Transaction** — business processing for a transaction.
- **Set Transaction Status** — success/failure status, retry semantics, transaction outcome.
- **End Process** — clean shutdown and resource cleanup.

Do not move business logic across states solely because it is convenient for the AI.

### Simple Process projects

Preserve clear separation of:

- initialization/configuration,
- business processing,
- exception handling,
- cleanup.

## Exception handling

- Use a business exception only for a known business-rule failure that should not be treated as an infrastructure/application defect.
- Use system/application exception behavior for technical failures according to the project's existing conventions.
- Never swallow an exception silently.
- Preserve existing retry semantics unless the change explicitly requires a retry-policy change.

## UI automation reliability

- Wait for elements or screen state; never use fixed delays to wait for a UI.
- Verify the result of every submit, save, or navigation step before continuing.
- Never set `ContinueOnError=True` on UI actions or click by coordinates alone.
- Prefer stable attributes, anchors, and wildcarded titles over indexes, generated IDs/classes, and dynamic text.
- Keep UI timeouts in Config and Retry Scopes bounded with a success condition.
- Follow `.github/instructions/browser-ui.instructions.md` for the full rules and the static robustness gate.

## Logging

Every new or changed log should be:

- meaningful to operations,
- concise,
- associated with relevant business/transaction context when available,
- free of secrets and unnecessary personal/sensitive data,
- consistent with the project's existing log-level conventions.

## Configuration and Orchestrator resources

- Do not hard-code environment-specific URLs, paths, credentials, asset values, queue names, or sensitive identifiers when the project already uses configuration/Orchestrator abstractions.
- Reuse existing config keys/resources where semantically correct.
- New config/asset/queue requirements must be declared in the change evidence.
- Do not create or mutate Production resources.


## Bot knowledge graph

- Each bot owns its own Graphify output. Do not create a cross-bot graph in the central Dev Kit. Graphify is reuse-first for existing bots and deferred until stable finalization for new bots; refresh once when the source fingerprint requires it.
- The graph is for retrieval and impact analysis; current UiPath source remains authoritative.
- Graphify is a mandatory bot-development dependency. The Coordinator runs managed-file integrity and, for an existing project, reuses or refreshes the bot-local graph before planning; new-bot work defers graph discovery until stable finalization. Pass the source fingerprint and graph state to downstream agents. Refresh final source state once when it changes; reuse final evidence after an Auditor PASS when fingerprints are unchanged.
- Graphing is code/XAML local-only. Do not enable semantic extraction of docs/media/Office files or any remote Graphify backend.
- Use the Dev Kit query/refresh wrappers so Graphify can be replaced without changing agent methodology.

## Managed Dev Kit core

- Treat every path marked `managed` in `.rpa-ai/kit-manifest.json` as read-only during bot development.
- Verify managed hashes with `.rpa-ai/scripts/Test-ManagedFileIntegrity.ps1` during Coordinator preflight and again only when managed state may have changed, evidence is stale, or suspicious modifications are detected.
- Restore or upgrade managed files only through a reviewed Dev Kit payload import; never patch one bot's agent, instruction, validation, or Dev Kit script files as a local workaround.
- Record reusable product limitations and proposals in bot-owned `.ai/feedback/dev-kit-improvements.md` without including business data, secrets, personal data, or Production details.

## User-profile tooling

- Developer servers may provide no administrator access and may install tools separately in each Windows user profile.
- Never assume `uip`, npm, Graphify, uv, pipx, Python, Node.js, or .NET is globally installed or available on `PATH`.
- Dev Kit activation installs missing portable Node.js/npm and `uv` under the current user's profile before installing the UiPath CLI and Graphify packages.
- Use `.rpa-ai/scripts/Resolve-DevKitTool.ps1` before direct tool execution. The resolver checks the current process, saved paths, and common per-user locations, then stores verified paths in ignored `.rpa-ai/local/tool-paths.json`.
- Do not require the user to edit machine or user `PATH` when a valid profile installation can be resolved directly.

## Dependencies and activities

Dependency setup is a **pre-development gate**. For every behavioral change, set `DEPENDENCY_SETUP_REQUIRED = true`, follow `dependencies.instructions.md` and `.rpa-ai/docs/DEPENDENCY-SETUP-PROTOCOL.md`, and set `DEPENDENCY_SETUP_COMPLETE = true` only after restore/install/verification. Record a dependency-state hash after restore; reuse it only when it still matches. Return `BLOCKED_DEPENDENCY` when a required capability cannot be verified.


## Browser UI automation

Browser UI work uses a **capture-first** policy. Any click, type, select, read, extract, submit, navigation, hover, upload/download-through-UI, or state check automatically sets `UI_CAPTURE_REQUIRED = true`.

For new browser work, Chrome is the default Development browser unless the requirement, existing project, or target application explicitly requires another browser. For UiPath workflows, prefer UiPath UI Automation activities and Object Repository/captured descriptors over coded workflows or external browser libraries. Code is an exception when explicitly requested, already established by the project, or required because no suitable UiPath activity exists; document that reason.

The Developer must proactively open/attach to the Development-safe browser/application and capture/prove all required targets **before** editing the UI workflow. It must not wait for a human reminder.

For UiPath deliverables, follow `browser-ui.instructions.md` and the installed official `uipath-rpa` skill: capture and prove every live Development target through UiPath UI Automation/Object Repository before authoring. Never guess selectors. Use the proven targets or return `BLOCKED_UI_CAPTURE`; `UI_CAPTURE_COMPLETE = true` requires browser attachment, complete target coverage, and interaction proof.

## Output artifact quality

Any process-generated business output file is subject to the task-specific `output-artifacts.instructions.md` and `.rpa-ai/docs/OUTPUT-QUALITY-PROTOCOL.md`. File existence is never sufficient; inspect the actual generated artifact, verify schema/data/readability, regenerate after defects, and set `OUTPUT_QA_COMPLETE = true` only after applicable checks pass.

## Outlook and email testing

When Outlook behavior is in scope, run `.rpa-ai/scripts/Test-OutlookCapability.ps1` after dependency setup. If unavailable, validate email construction independently and disclose that Outlook execution/delivery was not tested; never add test-only behavior to the production bot.

## Documentation and context

Use `documentation.instructions.md` for compact `AGENTS.md` context, topic-specific `.ai/context/` loading, and proportional documentation routing. The approved plan and Developer confirmation classify impact as `NONE`, `CONTEXT_ONLY`, or `HUMAN_DOCS`. Invoke RPA Documentation only for `HUMAN_DOCS`; update `AGENTS.md` only when stable agent-facing facts changed. Preserve targeted human-facing updates and Auditor verification.

## Generated scaffold validation exemption

A change may be classified **GENERATED_SCAFFOLD_ONLY** only when all changed implementation files are trusted template/scaffold output created by UiPath Studio or the official UiPath CLI and remain unmodified after generation.

For this class:

- restore/build/analyzer/diagnostics/functional execution are not required solely to validate the generated template;
- record generation provenance, CLI command when applicable, generated files, and confirmation that no post-generation behavior edit occurred;
- When invoked, Auditor must verify the exemption before PASS; an eligible `AUDIT_MODE: NONE` route has no Auditor verdict.

Any edit to generated behavior, arguments, dependencies, selectors, project wiring, or executable logic makes the change a normal **BEHAVIORAL_CHANGE** and restores the standard validation requirements.

## Definition of Done

An AI-generated RPA change is done only when:

1. business acceptance criteria are explicit,
2. pre-development dependency setup is complete for behavioral changes,
3. implementation is focused and traceable,
4. applicable mandatory validation gates pass, or a valid generated-scaffold-only exemption is verified,
5. relevant Development test/execution passes when safely runnable,
6. output-artifact QA passes when the process produces/changes business files,
7. behavioral R1 `AUDIT_MODE: NONE` has Developer self-review PASS, or the invoked Auditor returns PASS,
8. residual assumptions/risks are disclosed,
9. managed Dev Kit integrity passes,
10. the bot-local graph is refreshed and verified.
