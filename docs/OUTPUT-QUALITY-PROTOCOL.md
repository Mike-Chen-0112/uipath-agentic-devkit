# Output Artifact Quality Protocol

This protocol applies whenever an RPA process creates, exports, downloads, transforms, or updates a file that is part of the business deliverable.

Examples include:

- Excel workbooks (`.xlsx`, `.xlsm`, `.xls`),
- CSV/TSV files,
- PDF reports,
- Word documents,
- text/JSON/XML data exports,
- generated reports or extracts in other business formats.

A process is **not complete merely because the output file exists**. The output must contain the expected data and, when the format is intended for human use, it must be readable and appropriately formatted.

## Output QA state

When a requirement produces or materially changes a business output artifact, set:

- `OUTPUT_QA_REQUIRED = true`
- `OUTPUT_QA_COMPLETE = false`

After a safe Development execution generates the artifact, inspect the **actual process-generated file**. Do not substitute a manually edited copy.

Set `OUTPUT_QA_COMPLETE = true` only when the applicable data and presentation checks pass.

If the output fails QA, fix the automation/template that produced it and regenerate the artifact. Do not manually repair only the test output and call the process correct.

## Universal data checks

For every structured or report-like output, verify as applicable:

- expected file type and filename/path convention,
- file opens/parses successfully and is not corrupt,
- expected sheet/table/section/header names are present,
- required columns/fields are present and in the expected order when order is contractual,
- representative records contain the expected values,
- row/record counts are plausible and reconcile with the test input when a deterministic count is available,
- no obvious truncation, duplicated header rows, shifted columns, encoding corruption, or serialized object/debug text appears accidentally,
- dates, numbers, currencies, percentages, identifiers, and booleans are represented in a business-readable form,
- identifiers that require leading zeros are not converted to numeric/scientific notation,
- blank/null values are represented consistently with the business requirement,
- formulas or calculated fields do not contain visible error values such as `#REF!`, `#VALUE!`, `#DIV/0!`, `#NAME?`, or `#N/A` unless such values are explicitly expected,
- no credentials, tokens, secrets, or unintended sensitive/debug data are written to the output.

## Excel-specific presentation baseline

If an existing approved workbook/template is used, preserve its layout and style unless the requirement explicitly changes it. Do not restyle a template merely to satisfy this baseline.

For a newly generated human-readable workbook, apply a sensible baseline unless a downstream machine contract forbids it:

- meaningful worksheet names,
- visible and distinct column headers,
- appropriate number/date/currency/percentage formats,
- text format for IDs where numeric conversion would lose meaning,
- column widths that make headers and normal values readable,
- wrap text for long descriptive fields when useful,
- sensible row heights,
- freeze header rows for long tabular outputs when useful,
- filters or an Excel table for human-oriented tabular data when compatible with the business contract,
- consistent alignment and minimal professional formatting,
- no accidental hidden rows/columns/sheets containing required output,
- no clipped values, `#####` displays, or unreadably narrow/wide columns,
- no unnecessary empty default worksheets when the process owns workbook creation.

Avoid decorative formatting that changes business semantics or makes downstream parsing less reliable.

## Excel verification routes

Use the strongest available route without changing Production data:

1. Prefer opening the generated workbook in Excel/UiPath Excel tooling and visually checking the used range when Office is available and safe.
2. Also or alternatively, read the workbook back through UiPath Excel activities or the project's approved Python/.NET spreadsheet library to verify values, sheets, dimensions, number formats, formulas, and key style properties.
3. When a render/preview capability is available, inspect representative ranges visually for clipping and layout defects.

A successful write activity alone is not evidence that the workbook is readable.

## CSV/TSV outputs

CSV/TSV has no cell styling. Do not invent spreadsheet formatting requirements for a plain-text interchange format. Instead verify:

- correct delimiter,
- correct encoding (prefer UTF-8 unless the business contract says otherwise),
- header row when required,
- quoting/escaping of delimiters, quotes, and line breaks,
- stable column count,
- readable date/number/identifier representation,
- no mojibake or accidental scientific notation in identifiers,
- parseability by a standard reader.

If the business expects a formatted human report, CSV alone may be the wrong deliverable; follow the stated output contract rather than silently changing formats.

## PDF/Word/report outputs

For human-readable document outputs, open/render the generated artifact when tooling permits and verify:

- text is legible,
- headings/tables are not clipped or overlapping,
- page breaks are reasonable,
- required sections are present,
- fonts/characters render correctly,
- tables do not lose columns off the page,
- no placeholder/debug content remains.

## Machine-consumed outputs

When another system consumes the file, **contract compatibility has priority over cosmetic styling**. Do not reorder columns, rename headers, add tables, change delimiters, alter encodings, or introduce formulas/styles that could break the downstream consumer unless the requirement explicitly permits it.

Still verify parseability, schema, data types/representations, and representative data correctness.

## Downloaded third-party outputs

If the bot only downloads/relays a source-owned file and is not allowed to modify it:

- verify the downloaded file opens/parses and contains the expected business data,
- record readability/formatting defects as source-system issues,
- do not silently rewrite the artifact if that would violate the source/output contract.

If the process owns a post-processing step, correct readability/formatting through the automation and regenerate.

## Evidence minimum

Record:

- `OUTPUT_QA_REQUIRED: true`,
- output artifact path/name/type,
- generation/execution step that produced it,
- data checks performed and results,
- presentation/readability checks performed and results,
- representative sheet/range/section or record samples inspected,
- `OUTPUT_QA_COMPLETE: true` only after all applicable checks pass.

Do not persist sensitive business data in evidence. Summarize checks instead of copying full output contents.
