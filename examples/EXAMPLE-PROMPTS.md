# Example Coordinator Prompts

## New Process bot

> Read every accessible file in `.ai/intake/`. Create a new Portable Process project using official UiPath scaffolding, XAML workflows, and Visual Basic expressions. Implement the described process using Development resources only. Report unreadable intake files instead of inferring their content, then validate and audit the result.

## New REFramework bot

> Read every accessible file in `.ai/intake/`. Create a Windows REFramework project using an Official UiPath template. Preserve the standard Init, Get Transaction Data, Process Transaction, Set Transaction Status, and End Process responsibilities. Implement the business process, validate it in Development, and return scaffold, dependency, execution, output, and audit evidence as applicable.

## New bot with unresolved choices

> Read `.ai/intake/` and prepare this new bot. Ask me only for material choices that the documents do not resolve, including Process versus REFramework and Windows versus Portable. Default to XAML and Visual Basic. Do not create `project.json` or starter XAML manually.

## Bug fix

> The bot fails when Vendor ID is empty. Business wants the transaction skipped with a business-level reason while preserving existing retry behavior for technical failures. Implement this end-to-end in Development, validate it, audit it, and return the evidence.

## Browser UI change

> In the Development web portal, enter the case ID in the search field, click Search, and extract the displayed case status. Treat this automatically as `UI_CAPTURE_REQUIRED`. Before editing any workflow file, open/attach to the Development browser without waiting for another prompt, reach the search screen, capture and prove the Case ID field, Search button, and Status target with UiPath UI Automation, then set `UI_CAPTURE_COMPLETE`. Only after that implement the browser interaction, validate applicable gates, run a safe Development test, and audit the capture evidence before PASS.

## Existing fragile selector

> The Development bot intermittently fails on the Submit button because its selector is unstable. Inspect the live page, identify why the current target is fragile, use UiPath selector-improvement/target tooling when available, replace only the unstable targeting definition, validate, test the affected path, and audit the selector evidence.

## Generated template/scaffold only

> Create the requested UiPath project through the official UiPath CLI. Do not add business logic or edit the generated workflow afterward. Classify the task as generated-scaffold-only, record generator and template provenance, skip restore/build/analyzer/diagnostics/functional execution that would exist solely to validate the untouched generated template, and have the Auditor verify that the exemption is legitimate.

## Generated template then implementation

> Create a standard UiPath workflow template, then implement [business behavior] inside it. Because the generated workflow will be edited, treat the final change as a behavioral change, perform normal applicable validation, and audit the implementation.

## Change request

> Add a rule: invoices older than 90 days must be marked as business exceptions and must not be sent to SAP. Preserve all current handling for newer invoices. Implement, validate, test the affected paths in Development, and audit before returning PASS.

## Existing defect with logs

> Fix the failure represented by the attached Development log. First connect the error to the current business flow and impacted workflows. Do not change unrelated behavior. Implement the safest fix, validate, test if safely possible, and have the Auditor verify the result.

## Excel output quality

> The Development bot exports an Excel report with Transaction ID, Customer, Posting Date, Amount, and Status. Implement the output end-to-end. Treat the generated workbook as `OUTPUT_QA_REQUIRED`: after a safe Development run, open/read the actual generated workbook, verify the expected data and representative rows, preserve leading zeros in Transaction ID, use readable date/currency formats, make headers/columns readable without clipping, and check for formula/display errors. If the output is wrong, fix the workflow/template and regenerate it; do not manually repair only the test file. Audit the output evidence before PASS.

## CSV output quality

> The bot exports a CSV for a downstream system. Preserve the exact required column order and names. After a Development run, parse the actual generated CSV, verify UTF-8 encoding, delimiter/quoting, stable column counts, representative values, and leading-zero identifiers. Do not add Excel-style formatting because the file is machine-consumed. Require `OUTPUT_QA_COMPLETE` before PASS.

## Dependency-first development example

> Update this Development bot so it reads an Excel input, calls the approved REST endpoint, and writes a formatted Excel output. Do not tell me which packages you need. Derive the required dependencies from the process, restore/install and verify them before authoring executable workflow logic, then implement, test, perform output QA, and audit.
