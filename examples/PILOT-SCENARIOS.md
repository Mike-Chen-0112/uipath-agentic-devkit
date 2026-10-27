# Development Pilot Scenarios

Use non-sensitive Development test data. Each scenario ends with the selected audit-mode result and a final graph refresh; `LIGHT`/`FULL` scenarios include an independent Auditor verdict, while eligible `NONE` scenarios include Developer self-review evidence.

## Scenario 1: Existing-bot bug fix

**Goal:** prove a focused behavioral repair without changing managed Dev Kit files.

Prompt:

> In Development, reproduce and fix the current failure when an invalid employee ID is processed. Preserve retry behavior, classify the known invalid-ID rule as a business exception, validate the affected project, run the smallest safe test, and return audited evidence.

Expected evidence:

- managed integrity and initial graph refresh pass;
- dependency restore completes before authoring;
- current source and graph identify the affected exception path;
- focused diff with no managed paths changed;
- build/test result and the audit-mode result, including an Auditor verdict when invoked or Developer self-review when skipped;
- final graph refresh passes.

## Scenario 2: Browser selector repair

**Goal:** prove capture-first UiPath target work.

Prompt:

> The Development bot intermittently misses the Submit button. Open or attach to the Development page, capture and prove every affected UiPath target before editing, replace only the unstable target definition, run the affected path, and return selector evidence plus audit.

Expected evidence:

- `UI_CAPTURE_REQUIRED: true`;
- browser opened or attached before UI authoring;
- all required targets captured through UiPath UI Automation and safely proven;
- no guessed selectors;
- relevant Development execution passes.

## Scenario 3: Business output repair

**Goal:** prove data and presentation quality, not only file creation.

Prompt:

> Fix the Development result workbook so employee IDs keep leading zeros, dates are readable, rejection reasons are visible, and the existing downstream sheet contract remains unchanged. Regenerate the workbook and inspect the actual output before audit.

Expected evidence:

- actual generated workbook opened and parsed;
- headers, widths, formats, IDs, clipping, formula errors, and representative rows checked;
- workflow/template fixed rather than only the sample output;
- `OUTPUT_QA_COMPLETE: true`.

## Scenario 4: New Process bot

**Goal:** prove intake-to-scaffold behavior.

Prompt:

> Read every accessible file in `.ai/intake/`. Create a Portable Process project with Visual Basic expressions using official UiPath scaffolding, implement the Development-safe requirement, validate it, test it, inspect any generated business outputs, and return audited evidence.

Expected evidence:

- every intake file considered and unreadable formats identified;
- official CLI command family and built-in template recorded;
- collision-free scaffold transfer and hashes verified;
- graph refreshed immediately after scaffold;
- implementation reclassified as `BEHAVIORAL_CHANGE` when generated behavior is edited.

## Scenario 5: New REFramework bot

**Goal:** prove trusted template selection and framework semantics.

Prompt:

> Read `.ai/intake/`, create a Windows REFramework project from exactly one Official UiPath template, preserve standard state responsibilities and retry semantics, implement the Development process, validate, execute a safe representative case, and return audited evidence.

Expected evidence:

- Official package ID, version, source, framework, and expression language recorded;
- Marketplace templates rejected;
- Init, Get Transaction Data, Process, Set Transaction Status, and End Process responsibilities reviewed;
- dependency, execution, output, and audit gates handled according to the actual behavior.

## Pilot acceptance

A scenario passes only when the final outcome is `PASS`, all applicable evidence gates are complete, no Production resource was touched, managed integrity passes, and the final bot-local graph refresh succeeds. Record unavailable real-environment gates as `NOT_RUN`; never infer them from deterministic tests.
