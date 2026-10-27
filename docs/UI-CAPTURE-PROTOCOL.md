# UI Capture Protocol

This protocol prevents guessed selectors and repeated rediscovery. Resolve compatible live-validated project-local targets before opening an inspector, then capture only unresolved targets, screen by screen.

## Trigger

Any visible browser interaction automatically triggers `UI_CAPTURE_REQUIRED = true`: click, type, select, hover, read, extract, submit, upload/download via UI, navigation, or state verification.

## Defaults

- Use Chrome as the default Development browser for new browser activity unless the requirement, existing project, or target application explicitly requires another browser.
- Prefer UiPath UI Automation activities with live-captured targets/Object Repository descriptors for UiPath workflows.
- Use code or an external browser library only for an explicit code requirement, an established project convention, or a capability that no suitable UiPath activity provides. Record the reason.

## State machine

```text
Requirement contains browser UI
        |
        v
UI_CAPTURE_REQUIRED = true
        |
        v
Resolve Development entry point
        |
        v
LOOK UP .devkit/ui-targets/registry.json
        |
        v
Validate/reuse compatible target? ---- yes ----> record compact reuse evidence
        | no
        v
OPEN / ATTACH CHROME  <--- default for live validation/discovery
        |
        v
Reach required screen state
        |
        v
Inventory ALL required targets
        |
        v
Use the next supported strategy; do not repeat equivalent failures
        |
        v
Prove safe interaction/read for every target
        |
        v
UI_CAPTURE_COMPLETE = true
        |
        v
Author/edit workflow
        |
        v
Validate / debug / recover selectors if needed
```

## Hard rule

No UI activity/selector authoring is allowed between `UI_CAPTURE_REQUIRED = true` and `UI_CAPTURE_COMPLETE = true`. Run `Resolve-UiTarget.ps1` first, or use `Resolve-UiTargets.ps1` for one screen's inventory. Only a compatible `REUSED` target or newly live-validated `RESOLVED` target satisfies the per-target gate; static analysis alone does not. `VALIDATION_REQUIRED`, `BLOCKED_UI_CAPTURE`, and `UNRESOLVED_TARGET` do not authorize authoring.

## Local Target Registry

`.devkit/ui-targets/registry.json` is created on demand. Entries contain stable IDs, normalized web/native context, strategy and descriptor or Object Repository reference, anchors/fallbacks, deterministic quality, live/static validation distinction, capability fingerprint, source locations, warnings, and hashes. Screenshots are optional size-capped references, never inline state data.

The resolver deduplicates equivalent definitions and attempts, enforces the configured exploration budget, and emits `UNRESOLVED_TARGET` or `BLOCKED_UI_CAPTURE` instead of looping. Application/domain/route, target fingerprint, registry schema, and UI Automation capability changes invalidate fast reuse. Query strings and fragments are removed from page identity where safe.

An unchanged definition recorded as `VALIDATION_REQUIRED` may progress from static validation to live `PASS`, provided reuse validation has not failed. This does not permit equivalent failed attempts to repeat.

Accepted `REUSED` and `RESOLVED` responses include a compact `binding` with `targetId`, `primary`, `anchors`, and `targetFingerprint`. Use that binding instead of rereading the registry. Other statuses return a null binding.

## After capture: runtime robustness

A captured target can still fail at runtime if the workflow uses it badly. When quality reports `fallbackRequired: true`, add an anchor or fuzzy selector. After authoring, changed workflows are scanned by `UiWorkflowRobustness.psm1` during Developer validation: `ContinueOnError=True` on UI actions, coordinate-only clicks, and selectors with a PID, window handle, or session token block delivery; fixed delays, `idx` selectors, dynamic titles, typing without clearing, extreme timeouts, and unverified UI steps are warnings to fix or justify. See the runtime robustness rules in `.github/instructions/browser-ui.instructions.md`.

Capability analysis is cached within the PowerShell process for each project. The cache checks UI Automation dependency presence/version, hashes of selected local documentation contents, and Object Repository existence. Changed inputs invalidate the cache. Cached capability facts are not live target proof.

Default web hierarchy: registry -> Object Repository -> strict selector -> DOM selector -> anchor -> fuzzy -> semantic DOM -> semantic image/CV -> image -> coordinates. Native dialogs omit DOM strategies. Coordinates remain non-reusable last-resort evidence.

## UiPath vs Python

For UiPath deliverables, target capture must be done through UiPath UI Automation/Object Repository tooling, and the implementation should use UiPath activities whenever they support the action. Python DOM inspection can help diagnose the page but cannot prove a UiPath target.

For a deliberately Python-based browser implementation, capture/prove the real DOM locator first, then write the Python code.

### Official UI automation adapter

`scripts/Invoke-UiPathUiAutomation.ps1` in the central DevKit is a thin transport adapter, not a capture or selector-proof authority. It resolves the official tool through `Resolve-DevKitTool.ps1` and records command execution through `Invoke-DevKitCommand.ps1`. Use the installed official skill, the project-specific package guide, and current command help for supported operations and arguments; do not turn skill names into guessed CLI commands.

Non-help execution requires an approved Development project, non-sensitive Development data, explicit side-effect approval, a resolvable UI Automation dependency meeting the installed skill's prerequisite, and the project-specific `.local/docs/packages/UiPath.UIAutomation.Activities/ui-automation-guide.md`. Missing prerequisites block execution; the adapter does not upgrade packages automatically.

`CAPABILITY_AVAILABLE` establishes help availability only. `EXECUTED_UNVERIFIED` means a command ran, not that its artifacts are correct or a target is live-validated. The adapter retains `liveProof=NOT_VERIFIED` and `captureCompletionAuthority=false`. Inspect official results/artifacts, follow the package guide for activity binding or recovery, and satisfy the existing per-target resolver gates before authoring. Command exit zero, a JSON status, or an existing artifact cannot set `UI_CAPTURE_COMPLETE = true`. No live UI pilot or measured speedup is established by this integration.

## Multi-screen flows

Capture screen-by-screen. Attach once per needed Development browser context. Retain the current UiPath snapshot while its screen state and references remain valid; do not take a full snapshot for each target. Capture and prove all unresolved visible targets before advancing. Refresh after navigation, modal changes, rerendering, stale references, or another invalidating state change. Keep state-changing actions sequential; batch resolution does not authorize parallel clicks.

The agent may author a screen only after all targets for that screen are captured/proven. It must not invent later-screen selectors from prose.

### Compact screen-batch invocation

In an activated bot project, pass a compact JSON array to the wrapper:

```powershell
$targets = '[{"targetId":"screen.action","logicalName":"Required action","expectedRole":"button","candidates":[]},{"targetId":"screen.result","logicalName":"Required result","candidates":[]}]'
& .\.rpa-ai\scripts\Resolve-UiTargets.ps1 -ProjectPath . `
    -TargetsJson $targets -Domain $domain -Page $page -Json
```

Set `$domain` and `$page` to the approved Development context. In this source repository, the script is under `scripts/` rather than `.rpa-ai/scripts/`. This example starts registry resolution, not live capture; empty `candidates` do not prove unresolved targets.

- Supply 1–64 requests for one screen state, within the policy's compact input limit. Each needs a unique `targetId` matching `^[a-z0-9][a-z0-9._-]{2,127}$` and a nonempty `logicalName`.
- Each request may include `expectedRole`, `SourceLocation`, `ExpectedTargetFingerprint`, and reuse evidence fields `ReuseValidationStatus`, `ReuseValidationMethod`, `ReuseValidationDurationMs`, `ReuseMatchCount`, and `ReuseActualRole`.
- Put captured discovery evidence in each request's `candidates` array, not in a batch-level `DiscoveryCandidatesJson` parameter. Candidate fields include `strategy`, `descriptor` or `objectRepositoryReference`, optional `anchorDescriptor`, `matchCount`, `actualRole`, `validationLevel`, `validationStatus`, `validationMethod`, and `validationDurationMs`. Record actual tooling results; never label static evidence as `LIVE` or invent a `PASS`. Live acceptance still requires the same capability, context, quality, unique-match, and expected-role checks as single-target resolution.
- Context is shared through wrapper parameters: `ContextKind`, `Browser`, `Application`, `Domain`, `Page`, and `Window`. Resolve native dialogs in a separate `Native` batch.

The wrapper calls the same resolver sequentially for each target. It writes unique `<batchId>-<targetId>.json` evidence files and `<batchId>-summary.json` under `.ai/evidence/ui-targets` by default. The summary retains each target's status, binding, validation, and evidence path. It reports `PASS` and `uiCaptureComplete=true` only when every requested target is `REUSED` or `RESOLVED`; partial coverage remains `BLOCKED` without discarding accepted target evidence.

### Timing and benchmark limits

Single-target timing is labeled `RESOLVER_ONLY_NOT_END_TO_END_UI_CAPTURE`; batch timing is `RESOLUTION_BATCH_ONLY_NOT_END_TO_END_UI_CAPTURE`. Candidate evaluation is counted as `candidateEvaluationCount`, not as browser operations. Record actual UiPath capture/subprocess duration separately. Neither resolver timing nor supplied validation milliseconds measures end-to-end UI capture or task time.

The original v0.11.7 baseline was exported and the historical candidate snapshot was kept separately in `C:\Users\dinchen\RPAProjects\Test and Benchmark`. Both historical snapshots retain version 0.11.7; distinguish them by source/manifest hash, not the current release number. The requested live benchmark uses https://niklr.github.io/angular-material-datatransfer/ with GPT-6 Luna. No measured speedup is available yet. Compare total task wall time only at equal accepted quality, with the same task, inputs, environment, reset state, and quality gates; keep cold and reuse runs separate. If the required live UiPath capture or model is unavailable, report the benchmark blocked rather than substituting another stack or model.

## Failure

If the required browser, Development page, authentication state, or UiPath capture tooling is unavailable, return `BLOCKED_UI_CAPTURE`. Do not continue with guessed selectors. Placeholder-selector stub mode is allowed only when the user explicitly requests/delegates later indication.
