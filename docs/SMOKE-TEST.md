# Pilot Smoke Test

Run deterministic distribution checks first, then exercise the exported Dev Kit in disposable Development bot repositories.

## 0. Deterministic repository test

The default command is a focused current-version smoke test. It covers payload export, one fresh v0.11.8 import and activation, managed integrity, Graphify isolation, current Process scaffolding, Outlook capability persistence, UI Target Registry fixtures, native-validation fixtures, and stable remote-version detection. The `-Full` suite also covers update preservation and compatibility scenarios.

```powershell
./scripts/Update-SourceManifest.ps1 -Check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./tests/Test-DevKit.ps1
```

Expected: the focused suite ends with `[PASS] Dev Kit deterministic tests`.

The current-version check is cached for 24 hours. Use `-Force` on `Check-DevKitRemoteVersion.ps1` to exercise a fresh remote lookup. Behavioral validation may use `Get-DependencyState.ps1 -Verify` to reuse a proven pre-authoring restore; `CHANGED` and `UNCERTAIN` states must restore again.

Run the extended regression suite separately when validating importer security, managed-file conflicts, legacy/previous-version upgrades, fallback CLI compatibility, and negative scaffold cases:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./tests/Test-DevKit.ps1 -Full
```

The `-Full` suite is the release-cycle regression check. Run it under both Windows PowerShell 5.1 and PowerShell 7+ when both runtimes are available.

## 0.1 Export the payload

```powershell
./scripts/Export-RpaAiDevKit.ps1 -OutputDirectory ./artifacts -Force
```

Inspect the folder and ZIP. Confirm central tests, backlog, source templates, and release-maintenance files are absent.

## 0.2 Real greenfield projects

On a Development Windows workstation with `uip`, copy the payload into a disposable empty repository and create:

1. one blank Process project;
2. one Official REFramework project.

Verify `project.json`, generated workflows, explicit target framework and expression language, preserved `.ai/intake/`, collision-free transfer, and `.ai/evidence/project-scaffold.json`. If `uip` is unavailable, mark this `NOT_RUN`; deterministic fake-CLI tests do not replace it.

## 1. Agent files load

In VS Code, open Chat Customizations diagnostics and confirm:

- RPA Coordinator
- RPA Developer
- RPA Documentation
- RPA Auditor
- rpa-standards skill
- browser UI instructions
- UiPath official skills

show without errors.

## 2. Graph is present

```powershell
./.rpa-ai/scripts/Test-ManagedFileIntegrity.ps1
./.rpa-ai/scripts/Get-DevKitDiagnostics.ps1
./.rpa-ai/scripts/Refresh-BotGraph.ps1 -Mode Status
```

Expected: managed hashes pass, the pinned Graphify version is reported, and a non-empty valid `graphify-out/graph.json` is found.

## 3. Graph query works

```powershell
./.rpa-ai/scripts/Query-BotGraph.ps1 `
  -Question "Which XAML workflows are most connected?"
```

Expected: graph results; no source file is changed.

For release acceptance, capture a process/network trace while refreshing and querying with the real pinned Graphify CLI. It must show no non-loopback Graphify runtime connection. Package installation is a separate approved inbound-download step and must not include bot content.

## 4. Behavioral-change baseline validation

```powershell
./.rpa-ai/scripts/Validate-RpaProject.ps1
```

Record any pre-existing failures.

## 5. Browser UI Automation capability

```powershell
uip rpa uia --help
```

Expected: the installed Studio/UI Automation integration exposes the live UI Automation subgroup appropriate to that workstation.

On an approved Development/test page, ask the Developer to perform a dry discovery only. Do **not** remind it separately to open the browser:

> Do not edit source. Open or attach to the Development browser page, identify the [named button/field/table], and prove the target can be resolved. Prefer UiPath UI Automation agent tooling. Return selector/target evidence only; do not use Production data.

Confirm:

- the agent recognizes `UI_CAPTURE_REQUIRED` from the task itself,
- the agent opens/attaches to the browser without a second human reminder,
- the agent actually inspects the live UI,
- it does not invent a selector from the prompt,
- every target named by the task is captured/proven,
- `UI_CAPTURE_COMPLETE` is only set after that,
- no secrets/sensitive content are persisted,
- the evidence says whether UiPath or Python was used.

## 6. Coordinator dry run

Ask RPA Coordinator:

> Do not edit anything. Analyze this bot and explain the likely impact set if [small business rule] were changed. Use context, graph, then verify in source.

Check that it does not broadly read the entire project before using graph/context.

## 7. Generated scaffold exemption test

Generate a disposable template/scaffold file through UiPath Studio or the official UiPath CLI and do not edit it afterward.

Ask the Coordinator to assess the change.

Expected:

- classification is `GENERATED_SCAFFOLD_ONLY`,
- restore/build/analyzer/diagnostics/functional test are not run solely for that untouched generated template,
- provenance is recorded,
- Coordinator/Developer verify that no post-generation behavior edit occurred; an invoked Auditor independently verifies it when the selected audit mode requires one.

Then make a real edit to the generated workflow.

Expected: classification changes to `BEHAVIORAL_CHANGE` and normal applicable validation returns.

## 8. Small autonomous browser change

Use one reproducible, low-risk Development-only browser change, for example changing which field is read or which button is clicked on a test page. Confirm:

- Developer proactively opens/attaches to the Development browser and completes the UI capture gate before editing,
- Developer implements the verified selector/target,
- applicable validation evidence is produced,
- relevant Development execution is attempted when safe,
- Auditor independently checks selector quality and returns PASS/REWORK/BLOCKED,
- REWORK returns to Developer,
- PASS triggers graph refresh and a final managed-file integrity check,
- Coordinator's final answer is concise and evidence-backed.

## 9. Output artifact quality gate

Use a disposable Development test that generates an Excel workbook or CSV file. Do not tell the agent merely to check whether the path exists.

For Excel, use a test case that would expose common presentation/data defects, for example a long header/value, a date/currency field, and an identifier with leading zeros.

Confirm:

- the agent recognizes `OUTPUT_QA_REQUIRED` automatically;
- it inspects the actual process-generated artifact after execution;
- it verifies expected sheets/headers/data and representative records;
- it preserves leading-zero identifiers and uses readable date/number representation;
- for Excel, it checks widths/wrapping/number formats and catches clipping or `#####`/formula errors where applicable;
- for CSV, it checks delimiter/encoding/quoting/schema instead of pretending CSV has cell formatting;
- if a defect is found, it fixes the workflow/template and regenerates the output rather than manually editing only the test file;
- `OUTPUT_QA_COMPLETE` is true before completion, or before Auditor PASS when an Auditor is invoked.

## Dependency setup smoke test

Use a disposable Development project and a small requirement that needs one package/capability not currently present. Do not tell the Developer which package to add. Confirm that it:

- sets `DEPENDENCY_SETUP_REQUIRED = true`;
- derives the missing capability from the requirement and current project;
- restores already-declared dependencies before authoring;
- discovers/installs the genuinely required package with supported project tooling instead of hand-editing `project.json`;
- verifies the activity/import/package can be resolved;
- records dependency evidence and sets `DEPENDENCY_SETUP_COMPLETE = true`;
- does not author executable workflow logic before the dependency gate completes.

Negative test: make the required package unavailable from configured feeds. Expected result is `BLOCKED_DEPENDENCY`, not guessed XAML/type/import.
