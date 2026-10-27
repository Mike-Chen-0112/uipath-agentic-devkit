# Dependency Setup Protocol

## Purpose

Ensure the agent prepares all process dependencies before it begins implementation instead of discovering obvious missing packages only after authoring fails.

## Required ordering

```text
UNDERSTAND REQUIREMENT
        |
        v
IMPACT ANALYSIS
        |
        v
DEPENDENCY_SETUP_REQUIRED = true
        |
        v
BUILD DEPENDENCY INVENTORY
        |
        +--> declared UiPath package -> RESTORE
        +--> missing UiPath capability -> DISCOVER -> INSTALL
        +--> Python library -> PROJECT ENV / MANIFEST / LOCK
        +--> machine prerequisite -> VERIFY -> APPROVED INSTALL OR BLOCK
        |
        v
VERIFY RESOLUTION / AVAILABILITY
        |
        v
DEPENDENCY_SETUP_COMPLETE = true
        |
        +--> browser UI involved? -> UI CAPTURE GATE
        |
        v
AUTHOR IMPLEMENTATION
        |
        v
OFFICIAL CHANGED-FILE VALIDATE -> BUILD
        |
        v
APPLICABLE DEVELOPMENT / RUNTIME / OUTPUT QA / AUDIT
```

## 1. Derive dependencies from capabilities

Translate the process into technical capabilities before authoring. Typical package families include:

| Capability | Typical package family |
| --- | --- |
| Core workflow/system operations | `UiPath.System.Activities` |
| Browser/desktop UI Automation | `UiPath.UIAutomation.Activities` |
| Excel | `UiPath.Excel.Activities` |
| Mail | `UiPath.Mail.Activities` |
| Database | `UiPath.Database.Activities` |
| HTTP/REST | `UiPath.WebAPI.Activities` |
| PDF | `UiPath.PDF.Activities` |
| Word | `UiPath.Word.Activities` |
| PowerPoint | `UiPath.Presentations.Activities` |
| Testing | `UiPath.Testing.Activities` |

This is orientation, not a list to install wholesale. Current project dependencies, installed UiPath skills, configured feeds, and project compatibility are authoritative.

## 2. Restore existing UiPath dependencies first

`project.json` declares UiPath activity dependencies. Before activity discovery or executable authoring, restore them with the current supported UiPath workflow (`uip rpa restore` in the current CLI). Restore downloads/resolves what is already declared; it does not add a missing capability.

## 3. Install genuinely missing UiPath packages

When the requirement needs a capability not provided by current dependencies:

1. confirm an existing package does not already provide it;
2. discover the correct package and compatible version;
3. respect organization pins, configured feeds, target framework, and package compatibility;
4. install through the package command exposed by the installed official skill/current local help (`uip rpa packages install` or compatible `uip rpa install-or-update-packages`);
5. do not hand-author dependency entries when the supported package command is available;
6. verify the activity/type is now resolvable.

For `UiPath.UIAutomation.Activities`, first run `.rpa-ai/scripts/Get-UiPathEnvironmentCompatibility.ps1`. Preserve a valid existing pin. Evaluate the exact package's official nuspec minimum Studio requirement before the numeric release-line heuristic. A verified `MET` result permits cross-release selection without reviewed JSON and makes an available new-project candidate eligible regardless of release line. `NOT_MET` blocks selection even for a matching release line or reviewed reference. Do not choose a newer train solely because it is latest, and do not upgrade merely to enable optional semantic/CV behavior; use the supported selector fallback hierarchy instead.

Keep the project's generator version separate from the actual installed or supplied authoring host. Generator metadata does not establish the host's compatibility. The helper checks exact package ID/version nuspec metadata in project `.local/packages/UiPath.UIAutomation.Activities/<version>`, `.local/docs/packages/UiPath.UIAutomation.Activities/<version>`, user `.nuget/packages/uipath.uiautomation.activities/<version>`, and `AdditionalPackageRoots`. It parses an explicit description such as `requires Studio 24.10 or higher`, compares normalized versions, and hashes the metadata into compatibility evidence and the environment fingerprint. The official `26.10.6` nuspec declares `IMPORTANT: This package version requires Studio 24.10 or higher.` Its package release line alone therefore does not require Studio 26.10.

Missing or inconclusive metadata remains `UNKNOWN`; it does not verify a minimum requirement. Retain conservative release-line behavior, preferring the detected Studio/runtime line for new selection when no minimum is verified. The manual `-CompatibilityEvidencePath` route remains available with reviewed schema1 JSON that matches the actual `studioVersion` and `cliVersion`, identifies the package at its exact version, and includes an official HTTPS `docs.uipath.com` reference. Review the referenced documentation for the claimed compatibility: the URL is an evidence pointer, not proof on its own. An unsupported boolean or unknown host is not compatibility proof. Preserve valid pins rather than treating either evidence path as permission for an unrelated upgrade. Compatibility selection does not prove package installation, a successful build, or live UI capture; those gates remain required where applicable.

The package change remains part of the behavioral diff and must be audited/validated later.

## 4. Python dependencies

When Python is part of the approved design, use the bot's existing environment/package-manager convention, update/preserve its dependency manifest/lock convention, verify imports with the same interpreter used by the automation, and avoid unrelated upgrades or untracked global state.

## 5. Machine/runtime prerequisites

Verify required software outside the repository, such as Studio/Robot capability, browser UI Automation support, Excel/Office modes, drivers, runtimes, or approved CLI/SDK tools. Install proactively only when the method is approved, Development-safe, and permitted. Otherwise return:

```text
BLOCKED_DEPENDENCY
Required prerequisite: <name>
Reason: <feed/permission/auth/licensing/framework/policy/etc.>
Required resolution: <specific human/admin action>
```

Never substitute guessed implementation for an unavailable prerequisite.

### .NET runtime readiness

Use `.rpa-ai/scripts/Initialize-UiPathRuntime.ps1` to read the actual compiler runtimeconfig and architecture and verify the required .NET frameworks already available. Do not infer readiness from a generic .NET version check. If a runtime is missing, the script installs it automatically for the current user from official Microsoft distribution, without elevation or global PATH changes. Pass `-NoInstall` to only verify.

The runner must propagate a verified fresh local runtime record into the child .NET environment. Keep three results separate: runtime availability, compiler startup, and actual restore/build. A successful runtime check does not prove that the compiler starts or that a project restores or builds.

### Automatic recovery

Environment repair needs no approval and has no time budget. Optionally record setup time separately with:

```powershell
./.rpa-ai/scripts/ExecutionState.ps1 -Action EnvironmentStart -Reason "<scope>" -Json
```

End it with `-Action EnvironmentEnd -PhaseStatus PASS -Json` or `-Action EnvironmentEnd -PhaseStatus BLOCKED -Json`. This is a timing marker only.

Activation already restores the dependencies of an existing project and records `.ai/evidence/dependency-state.json`. The development approval covers continuation from the failed gate through implementation, capture, tests, output QA, and required audit. Do not request reapproval or repeat successful checks whose evidence remains fresh. Repairs are capped at three loops. Denied installation, authentication, UI access, licensing, or safety restrictions still require `BLOCKED` with the specific resolution needed. Recovery cannot bypass a required gate.

These are the recovery requirements, not evidence that an actual .NET installation, compiler run, restore/build, or browser test has completed. Record each performed action and its result separately.

## Outlook capability

When Outlook behavior is in scope, restore/install the project-approved UiPath package, then run `.rpa-ai/scripts/Test-OutlookCapability.ps1 -Json` before authoring. The probe combines package declaration with non-destructive access to the current user's default Inbox through Outlook COM MAPI and writes `.rpa-ai/local/outlook-capability.json`.

The result is machine/user-specific and rerunnable. A false result does not justify fake activities or test-only production branches. Use independent validation for email construction and business logic, and disclose that Outlook execution or delivery was not tested.

## 6. Completion evidence

For each required dependency/prerequisite record why it is needed, existing vs added status, version/constraint, source/feed/mechanism, restore/install action and result, verification of availability, and manifest/project files changed. Only then set `DEPENDENCY_SETUP_COMPLETE = true`.

After a successful pre-authoring restore, record the dependency fingerprint with:

```powershell
./.rpa-ai/scripts/Get-DependencyState.ps1 -Record
```

During later validation, reuse the restore only when this state reports `MATCH`. A changed, missing, malformed, or uncertain state requires `uip rpa restore` again. The Developer also emits a compact structured validation summary so the Auditor can consume deterministic results without repeating the same commands.

The state fingerprint includes dependency-relevant manifests, project compatibility settings, and the resolved UiPath CLI version. A matching fingerprint is the only basis for `RESTORE_STATUS: REUSED`; a different CLI version or project compatibility setting requires restore even when package manifests are unchanged. Every restore, diagnostic, build, and test result also records the source fingerprint it validates.

### Toolchain evidence

Use the installed official UiPath skill and current local CLI help for schema discovery, capture, descriptors, authoring, validation, build, and debugging. DevKit retains approval, risk decisions, Graphify, Target Registry, evidence, and output QA. Do not pin tooling to a version seen during research or upgrade dependencies just to complete this check.

Record the resolved CLI path/version, official skill path/hash and source provenance, project framework/activity versions, relevant package documentation/schema evidence, command capabilities, and capture prerequisites. `UiPathCompatibility.psm1` adds `toolchainEvidence` to the environment inventory and its fingerprint. Compatibility receives the actual resolved CLI launcher path/hash rather than relying on a version label alone. Skill `VERIFIED` means a local snapshot was hashed, not that a command or workflow ran. Package declarations and cached packages alone are not schema proof; command and capture capabilities need separate evidence. When UI authoring requires the project-specific official package guide, its absence blocks compatibility rather than being treated as sufficient `UNKNOWN` evidence.

### Validation and delivery gates

Restore must complete, or be safely reused from matching dependency evidence, before native diagnostics or per-file validation. `Validate-RpaProject.ps1` invokes official per-file validation for `ChangedWorkflow` through `Invoke-UiPathNativeDiagnostics.ps1 -CommandKind validate`, then builds the project. Per-file validation covers XAML and C#; discovery excludes generated, `.local`, and tool/build directories. With no supplied workflow list it discovers eligible project files; with none it blocks. The installed skill's command form is:

```text
uip rpa validate --file-path "<FILE>" --project-dir "<PROJECT>" --output json
```

Official `validate` is independent of risk-triggered `get-errors`; neither replaces the other. XML/static sanity checks are not official validation. Exit zero is insufficient: diagnostic errors, unrecognized required `get-errors` or `validate` output, malformed diagnostic collections or booleans, an unavailable command, or a timeout prevent delivery. Error entries containing only a code, or only `errorMessage`, cannot pass as clean diagnostics. Build and analyzer gates also require recognized successful response content, not just exit zero. Required changed-source validation and other required gates must complete; a later successful build cannot override a failed or missing gate. Build is compile evidence, not proof of runtime behavior, UI interaction, output correctness, or email delivery.

Runtime `ResultOnly` parsing keeps workflow `Error` log messages separate from actual execution failure. A workflow log level alone is not an execution outcome; inspect the command result and recognized runtime result content.

Per-file results are written to `.ai/evidence/uipath-workflow-validate.json`; the validation summary exposes `workflow_validate`, and the Developer summary exposes `workflowValidate`. The shared runner also retains legacy `getErrors*` fields for validate attempts; use `commandKind` and the command evidence to distinguish them. Reuse keys include command kind, workflow source hash, dependency/environment fingerprints, validation-policy hashes, and parser, resolved launcher, and project fingerprints. Final source freshness and required output QA also affect `deliveryReady`; required but unexecuted checks remain blocking.

The central DevKit integration is not a business-bot runtime validation. The Developer reports `Test-UiPathNativeValidation.ps1`, `Test-DeveloperFinalization.ps1`, and `Test-ExecutionReliability.ps1` passing after the stricter checks. These targeted control regressions do not prove real business-project validation/build, runtime behavior, live UI capture, pilot outputs, or a speedup. Earlier blocked and `REWORK` evidence remains historical evidence, not a successful runtime result.

## 7. What the gate does not replace

Pre-development dependency setup does not replace final restore/build/analyzer/diagnostics, Development execution, browser target proof, output artifact QA, or the audit mode's required review. Its purpose is ordering: prepare the environment first, then author against known available capabilities.
