---
applyTo: "**/project.json,**/*.xaml,**/*.cs,**/*.py,**/requirements*.txt,**/pyproject.toml,**/poetry.lock,**/uv.lock,**/Get-DependencyState.ps1,**/Validate-RpaProject.ps1"
---
# Pre-development dependency instructions

Dependency setup is a hard gate for behavioral development.

At the start of a behavioral change set `DEPENDENCY_SETUP_REQUIRED = true` and `DEPENDENCY_SETUP_COMPLETE = false`. Do not author executable XAML, coded workflows, or process Python until required dependencies are available and verified.

## Inventory first

Derive dependencies from both the requirement and current source. Consider current `project.json`, activity families, Python imports/manifests, browser/UI Automation requirements, Office/file-format needs, APIs/connectors, drivers, runtimes, CLIs/SDKs, and other prerequisites genuinely required by the chosen design. Do not add packages just in case.

## UiPath package rules

1. Restore packages already declared by the project before authoring/activity discovery.
2. If a capability is missing, use the installed official `uipath-rpa` skill/current CLI discovery to identify the correct compatible package.
3. Install new UiPath package dependencies with the supported command exposed by the installed official skill/current local help (`uip rpa packages install` or compatible `uip rpa install-or-update-packages`); do not manually write dependency entries into `project.json`.
4. Respect existing pins and target-framework compatibility. Prefer stable approved versions; do not upgrade unrelated packages or choose prerelease versions without justification.
5. Verify the intended activity/type is actually available after restore/install.

For Excel requirements, identify operations before UI work, select compatible UiPath Excel/Workbook activities, and verify package plus desktop-Excel prerequisites early. If capability evidence is absent, run one minimal temporary workbook write/read check using the selected approach and reuse it while dependency and environment fingerprints remain unchanged. Prefer compatible UiPath activities over COM or hand-authored Office XML; record any custom-code exception and its unsupported capability or environment reason.

## Python rules

Reuse the project's existing environment/package-manager convention. Keep dependency state reproducible through its existing `requirements*.txt`, `pyproject.toml`, lockfile, or equivalent. Do not rely on an unrecorded global install when the project uses a managed environment.

## Machine prerequisites

Verify non-project prerequisites such as UiPath Studio/Robot capability, browser UI Automation extension, Excel/Office modes, drivers, runtimes, or CLIs. Install missing ones automatically through a Development-safe, user-scoped mechanism without asking and without bypassing admin/security policy. Otherwise return `BLOCKED_DEPENDENCY`.

Prerequisite recovery never needs approval. Before returning a missing-runtime blocker, discover the actual compiler's runtimeconfig and architecture and run `Initialize-UiPathRuntime.ps1`; it installs a missing runtime for the current user by default. Keep existing runtimes, verify the selected host can load the required framework, then prove compiler startup separately and retry the failed dependency gate. Missing runtimeconfig, blocked installation, elevation, authentication or licensing needs remain real blockers; never guess or bypass them.

Setup time may be recorded separately with the `ExecutionState.ps1` EnvironmentStart/EnvironmentEnd markers; there is no setup time limit. Never label authoring as setup. Resume from matching failed-gate evidence rather than repeating a successful scaffold or restore.

## Outlook capability

When Outlook behavior is in scope, restore/install the project-approved package first, then run `.rpa-ai/scripts/Test-OutlookCapability.ps1 -Json` before authoring. The probe checks the declared UiPath Outlook/Mail package and performs non-destructive Outlook COM MAPI access to the current user's default Inbox. It records the rerunnable machine/user-specific result under `.rpa-ai/local/outlook-capability.json`.

`OUTLOOK_ACTIVITY_AVAILABLE = false` is an environment limitation, not an instruction to add a fake activity or a test-only production branch. The Developer must use the independent email validation path, and the Auditor must respect that result.

## Evidence

Record required capability, dependency/prerequisite name, existing/new status, version/constraint, source/feed/mechanism, restore/install/verification action and result, and files changed. Set `DEPENDENCY_SETUP_COMPLETE = true` only when every mandatory entry is verified. Reading a manifest or observing that a package name is declared is not enough; required restore/install/verification actions must actually be executed.

Record a dependency fingerprint over all dependency-relevant manifests, project compatibility settings in `project.json`, the resolved UiPath CLI version, explicit `availabilityStatus: VERIFIED`, and the local package-cache environment fingerprint. Reuse restore only when those inputs match a prior successful state exactly and package availability evidence is still valid. A missing, changed, malformed, uncertain, unavailable, or CLI-version-mismatched state requires restore; report reuse as `RESTORE_STATUS: REUSED`, never as an executed `PASS`. Run restore through `.rpa-ai/scripts/Invoke-DevKitCommand.ps1` so duration, exit status, timeout, and output are retained.

## UiPath UI Automation compatibility

Before selecting or changing `UiPath.UIAutomation.Activities`, run `.rpa-ai/scripts/Get-UiPathEnvironmentCompatibility.ps1`. Preserve a valid existing pin. Evaluate the minimum Studio requirement from the exact package's official nuspec before using the numeric release-line heuristic. `MET` permits cross-release selection without reviewed compatibility JSON, including an available new-project candidate; `NOT_MET` blocks selection even when release lines match or reviewed evidence exists. Never select a newer release train merely because it is newest. Record detected Studio, Robot/runtime, CLI, current and selected UI Automation versions, the compatibility decision, metadata evidence, and environment fingerprint.

Project `studioVersion` records the scaffold generator and must not substitute for actual installed Studio/headless-host identity. The helper reads exact package ID/version nuspec metadata from project `.local/packages/UiPath.UIAutomation.Activities/<version>`, `.local/docs/packages/UiPath.UIAutomation.Activities/<version>`, user `.nuget/packages/uipath.uiautomation.activities/<version>`, or `AdditionalPackageRoots`. It parses an explicit description such as `requires Studio 24.10 or higher`, compares normalized versions, and includes the metadata hash in compatibility evidence and the fingerprint.

Missing or inconclusive metadata remains `UNKNOWN`, not verified minimum-requirement compatibility. Retain conservative release-line behavior and prefer the detected Studio/runtime line for new selection when no minimum is verified. The manual evidence path remains available through `-CompatibilityEvidencePath`: reviewed schemaVersion 1 JSON with exact actual `studioVersion` and `cliVersion`, and `packages` entries with exact `version` plus an official HTTPS `docs.uipath.com` `reference`. Confirm the referenced documentation actually supports the host/package combination before recording it; a URL alone is not proof. The helper hashes this evidence and rejects mismatched identities. An unknown host cannot prove that a minimum is met; preserve the current version or block a new selection conservatively. Existing pins are preserved; selection is not installation, build success or live UI proof.

If a semantic, Computer Vision, or other optional capability is unavailable on the compatible package line, retain the normal strict-selector/DOM/anchor/fuzzy fallback hierarchy. Do not auto-upgrade the dependency to unlock an optional feature. Record package search, compatibility decision, dependency update, install, restore, cache/reuse, and CLI initialization using `Write-DeveloperEvent.ps1`; run their subprocesses through `Invoke-DevKitCommand.ps1` with `PACKAGE` category and a specific subcategory.

This gate does not replace final validation. Dependency additions remain part of the behavioral diff and still require applicable build/test/audit.
