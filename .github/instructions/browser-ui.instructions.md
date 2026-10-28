---
description: Use when the requested change includes browser or visible UI interaction; mandatory capture-first target discovery and selector-quality rules apply only to that task.
---
# Browser UI interaction rules

These rules apply whenever the requested behavior includes browser UI interaction: open/navigate, click, type, select, hover, submit, upload/download through UI, read/get text/get attribute, extract data, check element/app state, or any other visible-page action.

## Official Object Repository first; legacy Registry fallback

Start with `.rpa-ai/scripts/Get-OfficialObjectRepository.ps1 -ApprovedDevelopment -NonSensitiveDevelopmentData -Json` to inspect the current project's official OR without persisting a second store. The OR inventory is not live proof. Use the installed UiPath UIA skill/CLI to validate or capture each target before authoring. Only invoke the legacy `Resolve-UiTarget.ps1` for an existing Registry/inline-selector workflow; do not create a parallel registry for a new target.

Official-first sequence: OR inventory -> live validation of a compatible OR target -> official UIA capture/configuration/improvement for unresolved targets. Legacy projects may use the existing bounded Registry selector hierarchy only as a compatibility fallback. Do not invent selector strings or treat a CLI success code as a live UI proof.

Treat `REUSED` or live-validated `RESOLVED` as target-resolution completion. `VALIDATION_REQUIRED`, `BLOCKED_UI_CAPTURE`, and `UNRESOLVED_TARGET` never authorize UI authoring. A static `PASS` is not live proof. Record the resolver evidence path, reuse result, quality, validation level, application/page context, attempts, fallback reason, and warnings. Referenced screenshots are size-capped and hashed; never copy their bytes into execution state.

Authority is: live validated UI > valid deterministic selector/target > registry metadata > semantic interpretation > historical evidence. A registry entry is reusable evidence, not permanent truth. Revalidate or rediscover when live validation fails, application/page or UI Automation capability changes, the target definition changes, the registry schema changes, or the user explicitly requests rediscovery.

### Screen-level resolution and capture

Inventory targets by screen state before exploration. Prefer one official OR inventory per project/session; use the installed official UiPath UIA skills/CLI to capture and validate unresolved targets. For pre-existing Registry targets only, `Resolve-UiTargets.ps1` can batch legacy compatibility checks. Neither inventory nor batching supplies live target proof.

Attach to the approved Chrome window once per required screen context. Reuse the current UiPath snapshot only while its screen state and references remain valid. Capture and prove all unresolved targets visible in that state before navigating away; do not repeat a full snapshot for each target. Refresh after navigation, modal changes, rerendering, stale references, or another invalidating state change. State-changing actions stay sequential; batching resolution does not authorize parallel clicks.

Use returned bindings instead of rereading the registry. Capability analysis is reused within the PowerShell process only after dependency, documentation-content, and Object Repository state checks; it is not cached live-target proof. Static-to-live validation progression is allowed for the same definition, but equivalent failed attempts remain blocked. Record actual UIA subprocess duration separately from resolver candidate-processing duration; neither a batch timer nor supplied validation milliseconds represents end-to-end task time.

## Browser and implementation defaults

- **Default browser:** Use Google Chrome for new browser activity targets unless the requirement, existing bot contract, Development environment, or target application explicitly requires another browser. Do not silently switch to Edge, Firefox, or a code-driven browser when Chrome is available.
- **Default implementation:** Prefer UiPath UI Automation activities and captured UiPath targets/Object Repository descriptors for UiPath workflows. Use the appropriate activity for the action, such as application/browser scope, Click, Type Into, Get Text/Get Attribute, Select Item, Check App State, or extraction activities.
- **Code exception:** Use a coded workflow, Python, Playwright, Selenium, or another code block only when the requirement explicitly selects code, the existing project already uses that implementation, or no suitable UiPath activity can provide the required capability. Record the reason and preserve the same capture/proof requirements.
- **Chrome availability:** If Chrome is unavailable on the Development machine, return `BLOCKED_UI_CAPTURE` or document the approved alternate browser decision. Do not silently change the browser as an implementation shortcut.

## HARD GATE: UI_CAPTURE_REQUIRED

The moment a requirement contains any browser UI action, set `UI_CAPTURE_REQUIRED = true`.

**No workflow/code authoring for that UI step may begin until `UI_CAPTURE_COMPLETE = true`.** Reading the minimum context/config needed to find the Development URL and understand the intended screen is allowed; editing XAML, coded workflows, Object Repository consumer code, or Python implementation logic is not.

The official OR inventory is the first noninteractive targeting action. Opening/attaching to the live Development UI remains mandatory for target proof, and an absent OR entry does not authorize guessing a selector.

## Target binding and stale-target recovery

Normal sequence: establish the current screen state -> capture/resolve the intended target -> bind the captured UiPath descriptor to the UiPath activity -> perform and verify the intended activity. Inspection-tool references, screenshots, DOM locators, and temporary handles are not UiPath descriptors and cannot substitute for generated-bot validation.

On a stale-reference or target-not-found error:

1. Record failed validation through `Resolve-UiTarget.ps1 -ReuseValidationStatus FAIL`; never retry the same target/strategy with equivalent input.
2. Let the resolver advance to the next supported strategy within the configured exploration budget.
3. Obtain a fresh snapshot only when registry reuse and cheaper deterministic strategies cannot settle the target.
4. Resolve the intended element by meaning and surrounding context, then link/configure it using the supported UiPath tooling documented by the installed skill.
5. Inspect the resulting XAML diff for unintended argument, variable, namespace, or invocation-contract changes.
6. Validate the fresh target again with the intended activity and persist it as `REUSABLE` only after live `PASS`.

If one fresh-capture recovery fails, diagnose before another attempt: wrong window, wrong UI technology, wrong element, missing browser integration, or unsupported descriptor. Do not invent CLI commands or flags. Record the selected browser, screen, target, and failure/recovery reason in the existing UI evidence; do not create a separate document for each element.

## Chrome download prompt

When Chrome is configured to ask where to save each download, a webpage download has two UI states: the webpage download control and the native Chrome Save As dialog. Treat them as separate targets and capture both before authoring.

1. Capture and prove the webpage download action in the current screen state.
2. Trigger the safe Development download and capture the native Save As dialog using the supported UiPath UI Automation tooling. Do not assume the browser silently saves to its default folder.
3. Use the approved/configured destination from the plan or file journey. Do not hardcode a machine-specific path, filename, or selector.
4. Bind the captured dialog targets to UiPath activities for filename/path entry and the save confirmation action. Prefer the installed UiPath file/download activity when it supports the required prompted-save behavior; otherwise use the captured native dialog activities and record why.
5. Verify the actual downloaded file after the dialog completes, including existence, expected name/type, and output-artifact QA when it is a business file.

If the Save As dialog is missing, belongs to the wrong window, or cannot be captured, return `BLOCKED_UI_CAPTURE`; do not click through blindly or claim the download completed. Record the browser setting, webpage target, native-dialog targets, destination decision, and any recovery reason in the existing UI/file/output evidence.

## Mandatory capture-first sequence

For each browser UI task, execute this sequence in order:

1. **Recognize UI work.** List the business UI steps and targets: e.g. `Type Case ID -> SearchField`, `Click -> SearchButton`, `Read -> StatusLabel`.
2. **Load the official UiPath RPA/UIA procedure.** Invoke/read the installed `uipath-rpa` skill and, for UiPath UIA work, the installed package guide under `.local/docs/packages/UiPath.UIAutomation.Activities/` when present. The installed guide/CLI is authoritative.
3. **Resolve the Development entry point.** Get the approved Development URL/application from `.ai/context/`, config, or current source. Never use Production.
4. **Resolve registered targets first.** Run the deterministic resolver for every logical target with browser/application/domain/page context. Do not open an inspector merely because inspection is available.
5. **Choose and open/attach when live validation or discovery is required.** Default to Chrome unless an explicit exception applies. If no suitable Development Chrome window is open, launch it; otherwise attach/reuse it.
6. **Establish screen state.** Navigate only as far as required to validate or discover unresolved targets. Use non-sensitive Development test data. Do not type credentials; reuse an approved authenticated session or stop if authentication is unavailable.
7. **Validate reuse or capture/configure unresolved targets.** Use UiPath target validation/configuration, Object Repository, or indication tooling described by the installed `uipath-rpa` skill. Keep browser DOM and native dialogs as separate contexts.
8. **Prove each new target.** Perform a safe interaction/read against each newly captured target. Static selector inspection cannot be recorded as live validation.
9. **Record compact targeting evidence.** Record target ID/name, page/screen, strategy, quality, validation method/level, uniqueness/role result, reuse/fallback result, and referenced artifact hash/size.
10. Set `UI_CAPTURE_COMPLETE = true` only when all required targets resolve as validated reusable targets or newly live-proven targets.
11. **Only now author/edit the workflow.** Bind activities to the resolved UiPath descriptors/targets, or use the proven Python locators if the final implementation itself is Python.

For multi-screen flows, repeat steps 5-9 screen by screen. Do not author later-screen selectors from memory while only the first screen has been captured.

## UiPath implementation: UiPath capture is mandatory

If the deliverable is UiPath XAML or a UiPath coded workflow, the final UI interaction layer must use UiPath UI Automation. A Playwright/Selenium/DOM selector is **not** sufficient evidence for a UiPath selector because it does not prove UiPath can identify the target.

For UiPath UI work:

- use the current installed `uipath-rpa` skill's UI Automation flow;
- use the current `uip rpa uia` command surface/package documentation rather than inventing CLI syntax;
- configure targets/Descriptors/Object Repository entries before writing consumer activities;
- use selector-improvement/recovery tooling when a live-captured target fails;
- never hand-author a selector in XAML when live target capture is available.

Route every supported `uip rpa uia` subprocess through `.rpa-ai/scripts/Invoke-DevKitCommand.ps1` with category `UIA` and a precise generic subcategory (`capability`, `snapshot`, `navigate`, `live_capture`, `target_capture`, `target_generation`, `target_validation`, `selector_inspection`, `target_query`, `activity_link`, or `native_interaction`). Record the target lifecycle separately as `ui.target.capture`, `ui.target.generate`, `ui.target.live_validation`, `ui.target.resolve`, `ui.target.persist`, or `ui.target.reuse`. Object Repository work records generic lookup/open/create/update/assignment/save/link operations and an overall `USED`, `NOT_USED`, or `UNAVAILABLE` status. Do not combine a browser sequence into one opaque timer, and do not place DOM, screenshots, or command output inline in telemetry.

### Official command execution entry point

Use `.rpa-ai/scripts/Invoke-UiPathUiAutomation.ps1 -TargetBotPath <project> -Json` for the resolved official CLI's non-interactive UIA help probe. For an actual operation, supply `-CommandName <documented CLI command> -ArgumentList <documented arguments> -Subcategory <precise operation> -ApprovedDevelopment -NonSensitiveDevelopmentData -AllowSideEffects`, the current `-ExecutionStatePath`, and an appropriate timeout. Nested commands are supported either as a space-separated `-CommandName 'target-app resolve-defaults'` or as leading subcommand tokens (`-CommandName target-app -ArgumentList resolve-defaults,--refs,<ref>,--name,<name>`). The adapter resolves the actual `uip` through `Resolve-DevKitTool.ps1`, checks the project's exact declared UIA version against the installed skill's minimum and requires the project-local package guide. It resolves the command path one level at a time, accepting a segment only when the parent's official `--help` declares it as a subcommand and the child's help identifies itself with that exact command and `uip rpa uia <path>` usage. After the path, usage may contain only options, `<placeholders>`, `[optional groups]`, `{choices}`, or `...`; options listed outside brackets (for example `--refs <string> --name <string>` for `target-app resolve-defaults`) are required and are enforced before execution. Leading tokens stop being treated as subcommands at the first option or at a leaf; option values and later positionals are never subcommands. Options after the leaf are validated against the leaf help only (its own and global options), with value arity taken from the declared placeholders: `--option value` and `--option=value` for long options that take a value; missing values, inline values on flags, missing or extra positionals, unknown subcommands, a group command without a subcommand, and parent-only options placed after the leaf are rejected before execution. Arguments are passed as an array in their original order and boundaries. It dispatches through the shared runner and never installs/upgrades packages.

Read the installed skill and project package guide **in full**, plus their required capture/configuration/OR/recovery references, before choosing command arguments. `uia-configure-target` and `uia-improve-selector` are **skill/procedure names, not CLI verbs**. Follow the guide's staging, skill execution, generated configuration/descriptor, write-back and Object Repository binding procedure as applicable; do not substitute a guessed `uip rpa uia uia-configure-target` command. Package-version-specific commands not discoverable from current help are blocked; do not bypass the missing syntax evidence.

Before non-help UIA execution, use the existing environment gate with `Get-UiPathEnvironmentCompatibility.ps1 -ProjectPath <project> -CliPath <actual resolved uip> -CliVersion <executed verified version> -RequiredCapability ui.authoring -Json`. Required toolchain evidence must pass and compatibility uncertainty must be resolved under the dependency policy. The adapter's version/guide check does not replace dependency restore, installed activity capability, browser integration, or live-session checks. Do not supply a guessed CLI version to satisfy the gate.

All non-help operations are conservatively side-effecting and sequential, including reads that may initialize UIA. Timeout is **not cancellation** for a side-effecting process: inspect the returned process ID and do not launch another interaction until the first is settled. Use only non-sensitive Development data; the shared runner records official output in referenced command logs. Never pass credentials/tokens, capture sensitive pages, or copy DOM/screenshots/output into state. Follow official output-file options from current help and retain compact path/hash/size artifact references only.

`CAPABILITY_AVAILABLE` means only recognized CLI help ran. `EXECUTED_UNVERIFIED` means only the official subprocess completed with nonempty output; **unknown output is not success**. Empty/error-bearing/unavailable results are `BLOCKED_UI_CAPTURE`. Neither adapter status, supplied `PASS`, nor file existence sets `UI_CAPTURE_COMPLETE`. Inspect the actual official output/artifacts according to the installed package's result contract, verify the generated UiPath descriptor and intended activity in Development, then submit that evidence to the existing resolver/registration flow. Compatible targets remain reuse-first. No approved Development application/session means no live capture, no invented target and no business UI authoring; central adapter/control-test changes do not require creating a business bot.

For UI workflow execution, follow the installed `uia-starter-guide.md`: record window baseline, use the official `uip rpa debug start` (not `run`), inspect suspension/errors, cancel the execution and close only workflow-created windows after diffing against baseline. Route debug/cancel through `Resolve-DevKitTool.ps1` and `Invoke-DevKitCommand.ps1` as separate side-effecting operations with precise evidence; they are not `uia` child commands and are not routed by this adapter. On selector failure, first report reuse `FAIL` to the existing resolver, then follow the package's improve-selector recovery/staging/write-back procedure; inspect the XAML diff and re-prove the intended activity. Missing official skill/package guide/CLI capability returns `BLOCKED`, never a Python/Playwright fallback or automatic upgrade.

Python may inspect the DOM as supplemental diagnostics, but it cannot satisfy `UI_CAPTURE_COMPLETE` for a UiPath implementation by itself.

## Python implementation

If the business requirement explicitly chooses a Python browser implementation, or the existing project already implements that browser step in Python, the same capture-first gate applies. Use the project's existing browser stack; if none exists and a new dependency is approved, Playwright is preferred over Selenium for live DOM inspection.

For Python locators:

- inspect the live DOM;
- prefer role/name, label, stable test IDs, accessible names, or other semantic attributes;
- avoid generated IDs, session values, timestamps, brittle CSS chains, and arbitrary `nth`/index selectors;
- prove the locator uniquely resolves the intended element in the relevant state;
- prove the intended safe click/type/read/extract behavior.

## Selector/target acceptance requirements

A target is accepted only if all are true:

- captured from the live Development UI or safely reused from a compatible live-validated registry entry;
- corresponds to the intended business element;
- resolves in the relevant screen state;
- does not depend on obviously volatile/session-specific attributes unless no stable alternative exists and the risk is documented;
- handles legitimate duplicates through stable context/anchors rather than arbitrary position;
- is tested with the actual intended safe interaction/read;
- for UiPath implementations, exists as a UiPath target/descriptor usable by the workflow.

When the quality result reports `fallbackRequired: true` (score below GOOD with no reliable anchor), add a GOOD/ACCEPTABLE anchor or a fuzzy selector before accepting the target. Avoid selectors with `DYNAMIC_ID`, `GENERATED_CLASS`, `DYNAMIC_TEXT`, or `VOLATILE_VALUE` warnings when a stable attribute exists.

## Runtime robustness rules for authored UI workflows

Captured targets are necessary but not sufficient. Author UI activities so they survive slow pages, re-renders, and pop-ups:

- Attach to the browser or application by URL/process plus a wildcarded title, never by a full dynamic title, PID, or window handle. Use one tab per process and close it in cleanup.
- Never wait with a fixed `Delay`. Wait for the target or screen state (Check App State, Element Exists, Wait Element Appear/Vanish).
- After every submit, save, or navigation step, verify the resulting state: Check App State, an element wait, or the activity's Verify execution option when the installed UI Automation package supports it.
- Wrap state-changing steps that may be transiently slow in a Retry Scope with a condition that proves success; keep retries bounded and idempotent.
- Clear the field before typing (`EmptyField=True` / `EmptyFieldMode` not `None`).
- Read UI timeouts from Config; keep each between 3 and 300 seconds.
- Never set `ContinueOnError=True` on a UI action, and never click by screen coordinates alone.
- Let REFramework (or a Try Catch in a simple Process) take a screenshot and log the target on UI exceptions.

`Test-ChangedWorkflowSanity.ps1` (run by `Invoke-DeveloperValidation.ps1`) scans changed workflows with `UiWorkflowRobustness.psm1`. `UI_CONTINUE_ON_ERROR`, `UI_COORDINATE_ONLY`, and `UI_VOLATILE_SELECTOR` block delivery. `UI_FIXED_DELAY`, `UI_SELECTOR_IDX`, `UI_DYNAMIC_TITLE`, `UI_TYPE_WITHOUT_CLEAR`, `UI_TIMEOUT_EXTREME`, and `UI_NO_STATE_VERIFICATION` are warnings: fix them or record the reason in evidence. Run `Test-UiWorkflowRobustness.ps1 -ChangedFiles <xaml>` for a standalone scan.

## Forbidden behavior

When live Development UI access is available, the Developer must NOT:

- edit the workflow first and plan to choose selectors later;
- generate activities with guessed selectors and then validate them;
- infer selectors solely from screenshots, prose, HTML remembered from another task, or existing unrelated selectors;
- stop after opening the browser without capturing the targets;
- use Python/Playwright/Selenium as a shortcut to avoid UiPath target capture for a UiPath workflow;
- report `UI_CAPTURE_COMPLETE` based only on static XAML/selector inspection;
- ask the user to remind it to open the browser.

## Live capture unavailable

If the browser/app cannot be opened, the required Development page cannot be reached, authentication is unavailable, or UiPath target capture is unsupported on the workstation:

- do not guess;
- return `BLOCKED_UI_CAPTURE` with the concrete cause;
- only use a placeholder-selector stub if the user explicitly asked for/deferred that mode. A placeholder stub is not a completed automation and must be labeled as such.

## Evidence contract

Before the first source edit for a UI task, the Developer's working evidence must contain:

- `UI_CAPTURE_REQUIRED: true`
- `BROWSER_OPENED_OR_ATTACHED: true / N/A_REUSED_VALIDATED_TARGET`
- `CAPTURED_TARGETS: <count>/<required count>`
- one record per target: stable ID, business name, action, screen/page, registry reuse result, strategy, quality, validation level/method, descriptor summary, proof result, fallback/warnings
- `UI_CAPTURE_COMPLETE: true`

If any field is missing or false, the Coordinator must not authorize authoring and the Auditor must not PASS the change.
