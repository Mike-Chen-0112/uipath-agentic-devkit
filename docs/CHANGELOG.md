# Changelog

## Unreleased

### v0.12.1

- Fixed `Read-OfficialHelp` rejecting real leaf usage lines with `OFFICIAL_COMMAND_SYNTAX_UNAVAILABLE`. The 0.12.0 usage check accepted only `[`/`<` after the command path, but the CLI (1.204.0) prints explicit required options first, for example `uip rpa uia target-app resolve-defaults --refs <string> --name <string> [--project-dir <string>] ...`, and braced choices such as `[--type { Default | CV }]`. Usage is now validated as the exact `uip rpa uia <path>` prefix followed only by options, `<placeholders>`, `[groups]`, `{choices}`, or `...`; a bare word (another command) or a different path still fails closed. Options listed outside brackets are recorded as required, must be declared in the help's options, and are enforced before execution (`OFFICIAL_REQUIRED_OPTION_MISSING`, alias-aware). Table help now joins wrapped usage text, accepts bare argument names (`w/b-ref`), wrapped value placeholders followed by description text, and bracketed description continuations.
- Added regression fixtures with unmodified help captured from uip 1.204.0 in a Development bot project (`tests/fixtures/uia-help/actual-1.204.0`) and tests for both nested dispatch forms against them.
- Activation's dependency restore no longer aborts when the CLI writes warnings to stderr (for example, skipped tenant feeds while not logged in); the restore exit code alone decides PASS/WARN.

### v0.12.0

- Removed the execution time budget. Execution state still records wall, active, setup, and user-wait time and stage intervals for reporting, but no target, hard limit, performance state, or `BudgetCheck` action remains, and elapsed time never stops work or blocks delivery. Older active states are migrated on read. The command runner uses a fixed 30-minute default safety timeout instead of a remaining-budget timeout; `-ReserveSeconds` was removed.
- Raised the repair-loop cap from two to three.
- Made environment repair prompt-free. `EnvironmentStart` no longer needs `-ApprovedEnvironmentSetup` and is a timing marker only. `Initialize-UiPathRuntime.ps1` installs a missing runtime for the current user by default (`-NoInstall` verifies only); activation and installation take `-NoRuntimeInstall` instead of `-ApprovedRuntimeInstall`. The Coordinator's single development approval is the only user prompt; new-bot Process/REFramework and Windows/Portable choices are inferred and stated in that approval.
- Activation now retries a failed UiPath CLI install and Graphify install once, rebuilds a missing or invalid graph with `-Force`, restores existing project dependencies with `uip rpa restore`, and records dependency state for reuse (`-SkipDependencyRestore` to opt out). A failed restore is reported and left to the Developer to repair rather than blocking activation.
- Git is optional: the prerequisite check and activation warn instead of failing when it is missing.
- `Install-RpaAiDevKit.ps1` now upgrades unchanged managed files automatically; `-Upgrade` is retained for command compatibility.
- Added a static UI runtime-robustness gate (`UiWorkflowRobustness.psm1`, run by changed-workflow sanity and standalone via `Test-UiWorkflowRobustness.ps1`) for classic and modern UI activities. `ContinueOnError=True` on UI actions, coordinate-only clicks, and selectors containing a PID, window handle, or session token block delivery; fixed delays, `idx` selectors, dynamic window titles, typing without clearing, extreme timeouts, and unverified UI steps are reported as warnings that must be fixed or justified. Developer validation exposes them as `uiRobustnessWarnings`.
- Selector quality now penalizes numeric-suffix IDs, generated CSS classes, and dates/amounts in visible text, and reports `fallbackRequired` when a non-GOOD selector has no reliable anchor.
- Added runtime robustness authoring rules (state waits, post-action verification, bounded Retry Scopes, Config timeouts, attach by URL) to the browser-UI instructions, RPA standards, and Developer/Auditor prompts.
- Fixed `Invoke-UiPathUiAutomation.ps1` rejecting valid nested UIA commands such as `target-app resolve-defaults --refs <ref> --name <name>` and `snapshot capture ...` with `UNDOCUMENTED_OFFICIAL_OPTION`. The adapter queried only the first command level's help and validated every argument, including leaf subcommands and their options, against the parent's options. It now resolves the command path level by level from officially declared subcommands, verifies each level's help identity and full `uip rpa uia <path>` usage, validates options and positional arguments against the leaf help with declared value arity (`--option value`, `--option=value`), and reports the resolved `commandPath`. Unknown subcommands, group commands without a subcommand, missing option values or required arguments, extra positionals, and inline values on flags are rejected before execution. `-CommandName` also accepts a space-separated path. Safety gates, shared-runner execution, timeout handling, and the `EXECUTED_UNVERIFIED` (not live proof) status are unchanged.

### v0.11.9

- Harden UIA help parsing: reject error-bearing or malformed structural output, accept wrapped descriptions and format placeholders, and authorize only declared flags rather than tokens inside value placeholders. Correct the conflicting-prerequisite regression to use two valid declarations and check the exact conflict reason.
- Use the exact UI Automation package's declared minimum Studio version before release-line matching. UIA 26.10.6 accepts Studio 26.0.204.0 when its nuspec declares a 24.10 minimum, without requiring separate reviewed compatibility JSON. Preserve package pins and retain conservative handling when metadata is unavailable.
- Recheck package compatibility after restore and block unmet minimums before diagnostics or build. Added regression coverage for differing release lines, the exact minimum, lower and unknown hosts, missing metadata, new-project selection, and requirements first discovered during restore.
- Retain package metadata hashes in compatibility evidence and environment fingerprints. Package selection does not replace installation, build, or live UI capture.

### v0.11.8

- Added official per-file XAML/C# `validate` after restore and before build, excluding generated and `.local` files, while retaining risk-triggered `get-errors`. Required diagnostics reject unrecognized output, malformed collections/booleans, and code-only or `errorMessage`-only errors; build/analyzer gates require recognized successful content rather than exit zero. Runtime `ResultOnly` parsing separates workflow `Error` logs from execution failure.
- Bound compatibility evidence to the actual resolved CLI path/hash and added parser, launcher, and project fingerprints to validation reuse. A missing required official UI package guide blocks UI authoring compatibility; package declarations alone are not schema proof.
- Added a thin official UI automation transport adapter with Development/prerequisite gates and command evidence. Execution remains unverified until official artifacts and per-target proof are checked; it cannot authorize capture completion. Targeted validation/finalization/reliability tests are reported passing, not real runtime/UI pilots or measured speedup.
- Allowed static-to-live target validation progression while preserving equivalent failed-attempt blocking; accepted resolver responses now return compact bindings.
- Added process-local capability caching checked against dependency presence/version, selected local documentation content hashes, and Object Repository existence.
- Added screen-batch target resolution with unchanged per-target proof gates, unique target evidence, and a batch summary that keeps partial coverage blocked. Browser capture now groups visible targets by screen and reuses valid snapshots without parallel state-changing actions.
- Separated resolver/candidate-processing timing from end-to-end UI capture and stopped counting candidate evaluation as browser operations. The historical baseline and candidate snapshots both retain v0.11.7, identified by source/manifest hash; no measured benchmark speedup is claimed.
- Corrected parsing of official serialized `Data.runResult`: boolean `HasErrors` is required, malformed or unfinished results are blocked, and workflow log levels do not determine execution failure. The final central integration audit accepted the full regression and 21 official UI mock control checks; this is not live UI pilot, selector-recognition, or speedup proof.

### v0.11.7

- Added an idempotent, human-owned `Requirements/REQUIREMENTS.md` workspace for newly scaffolded blank projects, with read-only discovery for existing projects and preservation of every existing requirement file.
- Added inventory-first Coordinator discovery, selective supporting-file loading, explicit requirement precedence/conflict handling, and Developer safeguards that keep implementation, logs, runtime data, and evidence outside Requirements.
- Added compact content-free Requirements telemetry and lightweight Project Mapper metadata while excluding requirement artifacts from structural XAML mapping, Graphify extraction, and executable fingerprints.

### v0.11.6

- Added risk-triggered, content-parsed UiPath-native `get-errors` validation for generated or serialization-risk workflows and an enforced final project-build delivery gate. Required validation that is unavailable, fails, or is interrupted by the hard limit now persists an explicit non-deliverable state.
- Added environment-aware `UiPath.UIAutomation.Activities` selection that preserves valid pins, avoids unproven newer release trains, and falls back from unsupported optional targeting capabilities without package auto-upgrade.
- Added runtime enum reflection/cache and serialized-property validation. Optional unproven enum-backed properties are omitted; required incompatible properties block as `UIPATH_XAML_ENUM_INCOMPATIBLE`. Logical/DOM/semantic roles remain independent from serialized UiPath enum values.
- Added an append-only Developer JSONL event ledger, subprocess PID/exit/timeout evidence, nested inclusive/exclusive timing, source/edit-cycle and UI-target lifecycle taxonomy, conservative host/model-or-dispatch gaps, compact state references, runtime breakdown, and timing consistency checks.
- Preserved v0.11.5 Project Mapper, Fast Context, Graphify, Target Registry, risk-based Fast Lane, and Auditor routing behavior. Native diagnostics are not invoked after every write and remain skippable for eligible low-risk non-structural changes.

- Prepared the v0.11.5 local UI Targeting Layer: project-local schema-v2 registry, deterministic selector-quality scoring, capability-aware web/native strategy resolution, safe validated reuse, stale/context guards, bounded fallback attempts, duplicate prevention, compact artifact references, and per-operation timing/usage metrics without package upgrades or new services.

- Exclude UiPath's `.local/WorkflowFileValidator.cache` and other `.local/` runtime state from source fingerprints so a build cannot make its own evidence stale.
- Exclude tool-managed UiPath skill trees from executable/source fingerprints, reducing repeated hashing and preventing CLI skill refreshes from invalidating otherwise-current validation and graph evidence.
- Read persisted execution state explicitly as UTF-8 so non-ASCII command output remains stable instead of expanding through repeated Windows PowerShell 5.1 rewrites.
- Exclude installed Copilot skill payloads (`.github/skills/` and `.uipath/`) from local Graphify extraction so first activation cannot fail on zero-node skill metadata warnings.

### Changed

- Added conservative risk-proportional `get-errors` decisions for eligible R0/localized R1 changes, deterministic `.exe`/`.cmd`/`.bat`/PowerShell-hosted `.ps1` CLI resolution, per-run validation fingerprint reuse, detailed validation phase timings, targeted changed-workflow sanity, and bounded command-output/state-size evidence while preserving build/analyzer, Graphify, mapper, audit, and higher-risk diagnostics behavior.
- Added additive Developer lifecycle phase instrumentation, a Coordinator request-to-first-tool envelope, explicit `NOT_INSTRUMENTABLE` host/model boundaries, coverage reporting, and deterministic context-size profiling without storing prompt or source contents.
- Added a deterministic Developer Fast Context package with scoped Project Map neighborhoods, pre-materialized graph references, activity locations, source/graph freshness guards, auditable on-demand source expansion, conservative fallback reasons, and compact-context metrics.
- Added deterministic Developer validation and completion helpers that batch structural/normal validation, compact evidence, final fingerprints, Auditor handoff, and one atomic execution-state completion write with exact sub-timings and recovery tests.
- Added a deterministic local UiPath Project Mapper with normalized `project.json` metadata, namespace-agnostic XAML discovery, static/dynamic invoke relationships, forward/reverse dependencies, capability classification, warning-tolerant parsing, and an optional incremental `.devkit/cache/` cache. Coordinator, Developer, and Auditor now consume the compact map before expanding raw XAML scope, with mapping/read-count performance evidence and no new runtime dependency.
- Added explicit unfamiliar-activity schema verification and smallest-subtree XAML editing safeguards, including argument-contract diff checks and cheap XML validation between edits.
- Added Chrome-first stale-target recovery guidance with UiPath descriptor/activity binding, and Excel-first UiPath Excel/Workbook capability selection before browser work.
- Hardened execution-state writes with same-directory atomic replacement, concurrency detection, read-only status/report operations, and durable command output logs. Added focused reliability tests for state-write failure, silent/failed/timed-out commands, partial evidence, and fingerprint-based gate reuse.
- Set Chrome as the default browser for new UI automation and made UiPath UI Automation activities/Object Repository targets the preferred implementation; code-based browser automation now requires an explicit or evidence-based exception.
- Replaced the single wall-clock execution record with resumable schema-v2 state: active execution time controls budgets, total wall time and explicit user wait are reported separately, stages accumulate exclusive intervals, commands retain duration/exit/timeout/output evidence, completed runs are archived, and audit-required completion is enforced.
- Added shared schema-versioned source fingerprints that work without Git and separate executable, documentation, and Graphify configuration changes. Validation, Graphify, handoffs, and Auditor freshness now consume the same snapshot; successful deterministic gates may be reused only with matching source, dependency, CLI, and environment evidence.
- Added a shared timeout-aware command runner for restore, diagnostics, build, analyzer, scaffolding, and Graphify, with cautious handling for side-effecting functional execution and explicit hard-limit/LLM-control limitations.
- Combined Coordinator recommendation and development approval into one interaction and added a repeatable benchmark procedure in `docs/PERFORMANCE-BENCHMARK.md`.
- Added a persisted wall-clock execution budget with new-bot and existing-bot targets, hard-limit states, stage durations, bottleneck reporting, and a two-loop repair cap for standard task execution.
- Made new-bot routing check `project.json` before repository-specific analysis, defer Graphify until stable finalization, reuse unchanged Graphify and dependency state, and run cheap XAML/XML sanity before diagnostics, restore, and build.
- Made Coordinator planning default to one recommended solution, consolidated machine-facing execution details into one contract, and kept Auditor invocation proportional to R0/R1/R2/R3 risk and evidence.

## 0.11.3 - 03 Sep 2026

### Changed

- Added explicit `AUDIT_MODE` routing: R0 defaults to `NONE`, eligible localized R1 may use `NONE` after stricter Developer validation and self-review, other R1 defaults to `LIGHT`, R2 uses `LIGHT` or `FULL`, and R3 uses `FULL`; mandatory triggers always restore independent auditing.
- Added the exact `R1_NO_AUDIT_ELIGIBLE` conditions, mandatory audit triggers, Light Auditor outcomes, and no-audit Developer evidence contract while preserving all deterministic, dependency, browser/UI, output, Graphify, managed-core, and Production safeguards.
- Clarified residual scope, documentation, Graphify, scaffold, evidence, and final-report wording so `AUDIT_MODE: NONE` records Developer-owned proof and `Independent Auditor: SKIPPED`, while `LIGHT`/`FULL` records only an invoked Auditor result.
- Optimized Coordinator, Developer, and Auditor handoffs with reusable preflight state, structured Impact Sets, a Developer Audit Packet, risk-based audit depth, source-aware deterministic evidence, CLI-aware dependency fingerprints, and `get-errors` before the authoritative build. Successful checks are reused across handoffs and rerun only for explicit freshness, scope, or trust triggers.
- Reduced v0.11.3 agent prompt size by routing browser, output, dependency, documentation, file-journey, Outlook, Graphify, and risk-lane details through their scoped policies; removed remaining handoff-triggered Graphify/integrity rules and updated current-version documentation references.
- Added a structured `r1LightLane` block and matching `r1-eligibility-check`/`r1-scope-diff-verification` gates to `validation/validation-policy.json`, mirroring the existing `r0FastLane` block so agents have one machine-readable definition of what R1 narrows versus what stays mandatory.
- Added a git-based, content-fingerprinted incremental refresh to `Refresh-BotGraph.ps1`: an `-Mode Update` call now reuses the prior graph (`REUSED`) when the bot's tracked/untracked source and Graphify ruleset files (`.graphifyignore`, `.graphifyrc`, the version pin) are unchanged since the last successful refresh, and always falls back to a full extract when git is unavailable, the fingerprint differs, or `-Force` is passed. Graphify's own binary, backend, isolation, and query-logging behavior are unchanged.
- Added a deterministic test proving the incremental refresh extracts once, reuses on an unchanged repeat, re-extracts after a real source change, and always re-extracts with `-Force`.

## 0.11.1 - 02 Sep 2026

### Changed

- Added an R1 Light Lane for localized low-risk behavioral changes, reducing unnecessary discovery and regression scope while retaining applicable build/test validation, human approval, independent audit, and automatic escalation when broader impact is detected.
- Centralized R1 eligibility, targeted Coordinator planning, targeted Developer verification, targeted applicable validation, and lightweight R1 Auditor scope in `risk-routing.instructions.md` alongside the unchanged R0 Fast Lane rules, keeping agent prompts compact.
- Made the Developer and Auditor able to invalidate an R1 classification back to R2/R3 whenever implementation or review evidence shows wider impact than approved.
- Preserved the existing four-agent architecture (no new agents/subagents), the R0 Fast Lane, the R2 Normal Lane, the R3 Deep Lane, documentation routing (`NONE` / `CONTEXT_ONLY` / `HUMAN_DOCS`), and the unchanged Graphify architecture.

## 0.11.0 - 01 Sep 2026

### Changed

- Reduced expected processing latency by eliminating redundant reasoning and repeated deterministic validation across agent handoffs through an authoritative Coordinator-to-Developer Executable Change Plan.
- Made the Developer verify the approved plan rather than recreate it, report material `PLAN_DEVIATION`, and use R0-R3 risk classification for review depth.
- Made Auditor review evidence-first and diff-scoped while retaining independent semantic, business, safety, and risk judgment.
- Added structured validation summaries with deterministic validation reuse, including dependency-state fingerprints that distinguish a successful restore from `REUSED` state.
- Made Documentation Agent invocation conditional on verified documentation impact and reduced repeated policy procedures through instruction deduplication and selective task-specific routing.
- Cached non-critical remote DevKit version checks and preserved local integrity and Graphify behavior. No new agents were added; Graphify optimization remains intentionally deferred.
- Adopted compact persistent agent context with root `AGENTS.md` and topic-specific `.ai/context/` loading. Documentation impact now uses `NONE`, `CONTEXT_ONLY`, or `HUMAN_DOCS`; only `HUMAN_DOCS` invokes the Documentation Agent, while `CONTEXT_ONLY` updates `AGENTS.md` only when stable agent-facing facts change.
- Added an R0 Fast Lane for provably non-behavioral changes, using concise planning, minimal applicable deterministic validation, and lightweight independent audit while preserving human approval, integrity, safety, and traceability. Eligibility is explicit and conservative, and the Developer or Auditor can invalidate it back to the normal R1-R3 workflow at any time.

## 0.10.0 - 28 Aug 2026

### Added

- Added Coordinator solution selection with up to three distinct options, one recommendation, and the existing single development approval.
- Added RPA Documentation with standardized bot README and docs templates plus targeted Developer handoffs.
- Added machine/user-specific Outlook capability detection and independent email validation guidance when Outlook execution is unavailable.
- Added canonical Azure DevOps stable-tag detection and an explicit, rollback-protected Dev Kit update workflow.

### Changed

- Added documentation and Outlook evidence checks to the existing validation and audit flow without changing PASS, REWORK, or BLOCKED outcomes.

## 0.9.0 - 24 Aug 2026

### Added

- Added pinned, on-demand Humanizer and Caveman skills with protected technical-content boundaries and third-party license notices.
- Added the bot-owned `.ai/context/file-journey.md` template for logical file artifact lifecycles.
- Added Coordinator, Developer, and Auditor enforcement for file capability detection, lifecycle coverage, source cross-checking, and sensitive-content exclusions.
- Added file journey evidence fields and payload regression assertions.

### Changed

- Raised the current payload and documentation contract to the v0.9.0 Development pilot.
- Made the deterministic test command a focused current-version smoke test; retained the broader upgrade, security, and compatibility matrix behind `-Full`.

## 0.8.0 - 21 Aug 2026

### Added

- Added mandatory `Activate-RpaAiDevKit.ps1` and `Test-ManagedFileIntegrity.ps1` bot gates.
- Added bot-local diagnostics, troubleshooting, platform support, and Development pilot scenarios.
- Added preserved `.ai/feedback/dev-kit-improvements.md` for reusable product feedback.
- Added deterministic Windows PowerShell 5.1 compatibility coverage alongside PowerShell 7.
- Added persisted discovery of per-user tool installations and a no-admin one-command activation flow.
- Added SHA-256-verified portable Node.js/npm and `uv` bootstrap when the user profile has no UiPath or Graphify installer runtime.
- Added the temporary single-approval Coordinator gate before development.

### Changed

- Made Graphify mandatory during checked import and immediately after new-project scaffolding.
- Forced Graphify extraction to local code-only mode without clustering or query logging.
- Sanitized known cloud/model credentials from Graphify child processes and restored the caller environment afterward.
- Made graph refresh and managed-core integrity hard gates before bot work and after Auditor PASS.
- Marked manifest-managed agent, instruction, skill, validation, and script files immutable during bot development.
- Raised the payload and documentation contract to the v0.8.0 Development pilot.

### Compatibility

- Bot-side scripts support Windows PowerShell 5.1 and PowerShell 7+ on Windows.
- Recommended Copilot configuration is GPT-5.6 Luna with High reasoning, 200K context for routine changes, and 1M for greenfield or complex work when available and approved.

## 0.7.0 — 21 Aug 2026

- Added a generated bot payload and ZIP for copy-paste distribution into new or existing bot repositories.
- Added canonical payload ownership and SHA-256 metadata for managed-file upgrade preflight and bot-owned file preservation.
- Added official UiPath CLI greenfield creation for blank Process and Official REFramework projects, with current and compatibility command detection.
- Added isolated scaffold staging, structural verification, collision checks, and scaffold provenance evidence.
- Added provisional `.ai/intake/` support for human-created process documents without imposing a final document schema.
- Added checked existing-bot import and conflict-aware upgrade behavior.
- Renamed the generic `company-rpa` skill to centrally managed `rpa-standards`.
- Added deterministic fake-CLI tests for payload, import, Process creation, and REFramework creation.
- Added deterministic source release manifest generation and verification.
- Rewrote the README and setup guidance around distribution, new bots, existing bots, and testing-phase limitations.

## 0.6.0

- Added a hard pre-development dependency setup gate for behavioral changes.
- Developer must derive, restore/install, and verify required process dependencies before browser capture or executable authoring.
- Added `DEPENDENCY_SETUP_REQUIRED`, `DEPENDENCY_SETUP_COMPLETE`, and `BLOCKED_DEPENDENCY`.
- Added dedicated dependency instructions and `DEPENDENCY-SETUP-PROTOCOL.md`.
- Uses supported UiPath package tooling for new dependencies and `uip rpa restore` for declared dependencies; avoids manual `project.json` dependency editing.
- Added Python environment/manifest rules and machine-prerequisite verification.
- Coordinator/Auditor enforce dependency ordering and evidence.
- Added validation-policy, smoke-test, scorecard, and evidence updates.

## 0.5.0 — 20 Aug 2026

- Added mandatory `OUTPUT_QA_REQUIRED` / `OUTPUT_QA_COMPLETE` gate for business files created, exported, downloaded, transformed, or updated by a process.
- Explicitly prohibited treating file/path existence, nonzero file size, successful save/write, or download completion as sufficient output evidence.
- Added Excel data/readability/formatting checks: schema, representative rows, headers, widths, wrapping, number/date formats, leading-zero IDs, clipping/`#####`, formula errors, hidden required data, and template/downstream-contract compatibility.
- Added CSV/TSV checks for encoding, delimiter, quoting and schema instead of inappropriate cell-formatting requirements.
- Added human-readable PDF/Word/report open/render checks when tooling permits.
- Required fixing the producing automation/template and regenerating the artifact instead of manually repairing only the test output.
- Added `output-artifacts.instructions.md` plus `docs/OUTPUT-QUALITY-PROTOCOL.md`, and wired them into Developer, Coordinator, Auditor, evidence, policy, installer, smoke tests and pilot scorecard.

## 0.4.0

- Changed browser automation from "live discovery preferred" to a hard `UI_CAPTURE_REQUIRED` pre-authoring gate.
- Developer must proactively open/attach to the Development browser without waiting for a user reminder.
- Added `UI_CAPTURE_COMPLETE` state and required all business targets to be captured/proven before UI authoring.
- For UiPath XAML/coded workflows, UiPath UI Automation/Object Repository capture is mandatory; Python DOM inspection is supplemental only.
- Coordinator now rejects implementation that starts before browser capture is complete.
- Auditor now treats capture-order violations and Python-only evidence for UiPath selectors as REWORK.
- Added explicit `BLOCKED_UI_CAPTURE` behavior instead of silent selector guessing.
- Added upgrade guidance requiring `-ForceManagedFiles` so existing bots actually receive the new managed instructions.
- Preserved the generated-scaffold validation exemption from v0.3.0.

## 0.3.0 — 20 Aug 2026

- Added mandatory live browser UI target discovery for click, type, read, extract, select, navigation and state-check interactions.
- Made UiPath 26.10 agentic UI Automation capabilities the preferred target-discovery route (`uia-interact`, `uia-configure-target`, `uia-improve-selector`).
- Added Python browser tooling as a controlled fallback/intentional implementation route with live DOM and locator-quality requirements.
- Added selector-quality and selector-evidence checks to Developer, Auditor, company standards and evidence templates.
- Added `browser-ui.instructions.md` and installer support for it.
- Added `GENERATED_SCAFFOLD_ONLY` vs `BEHAVIORAL_CHANGE` classification.
- Added a validation exemption for untouched template/scaffold output generated by UiPath Studio or the official UiPath CLI.
- Required provenance + Auditor verification for the scaffold exemption; any post-generation behavior edit restores standard validation.
- Updated validation policy schema, methodology, setup, smoke tests, examples and source references.

## 0.2.0 — 17 Aug 2026

- Promoted Graphify from optional experiment to the default per-bot knowledge-graph provider.
- Pinned Graphify version for reproducibility.
- Added local-safe `.graphifyignore` policy focused on XAML/code/config parsing.
- Added Graphify install, query and refresh wrappers.
- Forced Graphify query logging off in Dev Kit wrappers.
- Added version mismatch guards to bot graph operations.
- Added optional Graphify git-hook support.
- Updated Coordinator to query the graph before broad repository retrieval and refresh it after PASS.
- Kept repository source as the authority over graph results.
