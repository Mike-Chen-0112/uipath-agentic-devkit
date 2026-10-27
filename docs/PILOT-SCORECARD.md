# Pilot Scorecard

Use one row per attempted change.

| Measure | Result |
|---|---|
| Bot | |
| Change / defect | |
| Change classification | BEHAVIORAL_CHANGE / GENERATED_SCAFFOLD_ONLY |
| Coordinator understood intent without re-prompt? | Yes/No |
| Browser UI interaction involved? | Yes/No |
| UI_CAPTURE_REQUIRED recognized automatically? | Yes/No/Not applicable |
| Agent opened/attached without a reminder? | Yes/No/Not applicable |
| Dependencies derived/restored/installed/verified before authoring? | Yes/No/Not applicable |
| `DEPENDENCY_SETUP_COMPLETE` before executable development? | Yes/No/Not applicable |
| All required targets captured/proven before authoring? | Yes/No/Not applicable |
| UI_CAPTURE_COMPLETE reached before source edit? | Yes/No/Not applicable |
| Selector/target evidence accepted by Auditor? | Yes/No/Not applicable |
| Capture route | UiPath UIA / Python implementation / Not applicable |
| Developer completed implementation without human edit? | Yes/No |
| Applicable validation completed automatically? | Yes/No/Exempt scaffold |
| Functional Dev test executed? | Yes/No/Not applicable/Not possible |
| Business output artifact involved? | Yes/No |
| OUTPUT_QA_REQUIRED recognized automatically? | Yes/No/Not applicable |
| Actual generated artifact opened/read/parsed? | Yes/No/Not applicable |
| Data/schema checks passed? | Yes/No/Not applicable |
| Readability/formatting checks passed? | Yes/No/Not applicable |
| OUTPUT_QA_COMPLETE before audit PASS? | Yes/No/Not applicable |
| Auditor found blocking issue? | Yes/No |
| Rework loops | 0 / 1 / 2+ |
| Final outcome | PASS / BLOCKED |
| Human interventions | |
| Total prompts from human | |
| Incorrect/unrelated changes | |
| Escaped defect after review | |
| Notes | |

## Pilot target

A good first milestone is not "zero humans." It is:

- one initial business prompt,
- no repeated steering between engineering steps,
- proactive browser opening plus complete capture-first target discovery for browser UI changes,
- deterministic applicable validation evidence or a correctly verified scaffold exemption,
- actual output data/readability/formatting QA when the process produces business artifacts,
- explicit audit-mode result: Developer self-review for eligible `NONE`, or independent audit for `LIGHT`/`FULL`,
- safe stop when information, UI access, or environment is insufficient.
