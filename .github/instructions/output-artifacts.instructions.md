---
description: Use when a process creates, exports, downloads, transforms, or updates a business output file; apply data, readability, and formatting checks only to that task.
---
# Output artifact quality rules

If the requirement creates, exports, downloads, transforms, or updates a business output file, set `OUTPUT_QA_REQUIRED = true`.

For a Chrome download configured to prompt for a save location, do not treat the webpage click as artifact creation. Verify the native Save As dialog action, the approved file-journey destination, the actual generated file, and the required data/readability/presentation checks after saving.

For Excel output, implementation selection is an early gate: record read/write, tables, formulas, formatting, and schema operations; select compatible UiPath Excel/Workbook activities and verify package and desktop-Excel prerequisites before lengthy browser capture or implementation. Reuse a successful minimal capability check while dependency and environment evidence remain unchanged. Custom code requires a documented unsupported-capability or environment reason.

A file-existing/path-existing check is never sufficient by itself.

After a safe Development execution generates the actual artifact:

1. open/read/parse the generated file with format-appropriate tooling;
2. verify expected schema/content and representative records;
3. verify business-readable value representation (dates, numbers, IDs, nulls, encoding);
4. for human-readable formats, inspect layout/presentation and correct unreadable formatting;
5. for Excel, verify headers, column widths, number/date formats, ID preservation, clipping/`#####`, long-text handling, and formula errors; preserve approved templates and downstream contracts;
6. for CSV/TSV, verify delimiter/encoding/quoting/column consistency rather than cell styling;
7. for PDF/Word/report outputs, render/open when possible and check clipping, overlap, page layout, missing sections, and placeholder/debug content;
8. if a defect is found, fix the automation/template and regenerate; never manually patch only the test artifact;
9. set `OUTPUT_QA_COMPLETE = true` only after all applicable checks pass.

For machine-consumed files, schema/contract compatibility takes priority over cosmetic formatting.

Use `.rpa-ai/docs/OUTPUT-QUALITY-PROTOCOL.md` for the detailed checklist and evidence requirements.
