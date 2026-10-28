---
description: Rules for editing UiPath workflows and project files.
applyTo: "**/*.xaml,**/project.json,**/*.json,**/*.config,**/*.xlsx"
---
# UiPath workflow editing rules

- Final validation retains risk-triggered `get-errors` and independently requires dependency availability, official per-file `uip rpa validate --file-path "<FILE>" --project-dir "<PROJECT>" --output json` for each changed workflow, then project build and applicable Development/runtime/output checks. Follow the installed official skill/current CLI syntax. Exit zero alone is not a clean diagnostic result; unavailable, timed-out, error-bearing or unrecognized validate output blocks delivery. Reuse requires current source, dependency, environment/CLI and policy fingerprints. A clean build never overrides a failed per-file gate or incomplete output QA.

- Inspect invoked workflows and argument contracts before changing a XAML workflow.
- Preserve argument direction, data type, and semantic meaning unless the requirement explicitly changes the contract.
- Prefer existing project packages and activity patterns before adding dependencies.
- For new browser interactions, default to Chrome and UiPath UI Automation activities. Do not introduce a code block when an existing UiPath activity can perform the required action.
- When activity choice is uncertain, use the installed UiPath skills/CLI discovery capabilities instead of inventing activity names or XML.
- Before authoring an activity or property not already demonstrated by a working compatible example: identify the installed package and exact version; inspect the installed package documentation, supported tooling, or a compatible working example; confirm the activity type, namespace, required properties, enum values, and argument structure; only then author it. If the schema cannot be verified, stop and report the missing information rather than guessing another property, enum, or activity name.
- For browser UI activities such as Click, Type Into, Get Text/Get Attribute, Select Item, Check Element, or extraction activities, set `UI_CAPTURE_REQUIRED` and complete the live-browser capture gate before writing/changing the activity or its selector/descriptor.
- For UiPath workflows, use UiPath UI Automation/Object Repository target capture. Python DOM inspection cannot replace UiPath capture; it may only supplement diagnostics.
- A coded workflow or external browser automation library is an exception path: require an explicit requirement, an existing project convention, or evidence that no suitable UiPath activity supports the action.
- Do not hand-author brittle selectors around volatile IDs, timestamps, session values, or arbitrary indexes when a stable live-discovered target is available.
- Keep changes local to the requested behavior.
- Modify the smallest necessary XAML subtree. Preserve root namespaces, `x:Members`, variables, and workflow invocation contracts. After selector linking or another tool-generated edit, inspect the diff immediately for unrelated removals or changes; if an argument contract is damaged, repair it before continuing. Use the validation helper for cheap XML checks and do not require a full build after every small edit.
- Preserve existing exception taxonomy (BusinessRuleException vs System Exception or project equivalent).
- Preserve transaction/retry semantics unless explicitly changed.
- Maintain existing logging style and include enough business context to diagnose failures without leaking sensitive data.
- Treat `project.json` dependency changes as architectural changes: explain why they are needed and audit them carefully.
- Do not edit binary Office/config artifacts unless the change is explicitly required and verifiable.
- A trusted UiPath Studio/official CLI-generated template file that remains unmodified is generated scaffold, not an AI-authored behavior change. It does not require standalone validation solely because it was created; once edited or wired into changed executable behavior, normal validation applies.

## Serialized property safety and native validation

- Keep logical role, DOM role/tag, semantic description, UiPath activity property, and serialized UiPath enum value as separate concepts. Never copy a semantic value such as `Link` or `Document` into `ElementType` unless the actual resolved `UIElementType` enum proves it valid.
- Before finalizing generated or changed XAML with enum/version-sensitive properties, run `.rpa-ai/scripts/Test-UiPathXamlCompatibility.ps1`. It reflects enum values from the resolved package assembly and caches metadata by package/assembly fingerprint. A static guess is not a substitute when reflection is available.
- Omit an optional enum-backed property when its value cannot be proven compatible. Never invent a substitute. A required invalid or unprovable property blocks with `UIPATH_XAML_ENUM_INCOMPATIBLE` and compact workflow/activity/property/value/type/package/runtime evidence.
- Treat related writes as one coherent edit cycle: author/configure/link, run cheap XML/structure/enum/package checks, then run one native diagnostic checkpoint when the risk facts require it. Do not run `get-errors` after every write.
- For a newly generated workflow/project or a change involving activities, serialized properties, selectors/targets, workflow interfaces, dependencies, generated XAML, or native repair, `Invoke-DeveloperValidation.ps1` must run UiPath-native `get-errors` for each affected workflow and parse its content even when the process exit code is zero. A failed diagnostic permits only a targeted, changed-source repair and rerun; identical source hash plus diagnostic fingerprint blocks instead of looping.
- A new or materially changed project requires the final project build. Files on disk, XML validity, or a skipped build cannot be reported as deliverable.
