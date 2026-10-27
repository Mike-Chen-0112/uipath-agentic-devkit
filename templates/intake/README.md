# Bot Intake

This is the legacy/pre-scaffold intake location for material supplied before a new UiPath project is initialized. After scaffolding, use the human-owned `Requirements/` folder at the project root as the canonical location; DevKit preserves this intake material.

The format is intentionally not standardized in this testing release. Typical inputs include:

- Markdown or text notes;
- Word or PDF process descriptions;
- Excel or CSV examples and business rules;
- screenshots or other approved supporting material when needed.

Include as much of the following as is known:

- bot purpose and business outcome;
- trigger and expected schedule;
- inputs and outputs;
- applications, approved Development URLs, and systems;
- process steps and decisions;
- business rules and exceptions;
- queue, asset, credential, and configuration names without secret values;
- Development test scenarios and acceptance criteria;
- preference for Process or REFramework, and Windows or cross-platform execution.

Agents must verify that the available tooling can actually read each supplied format. If a document cannot be extracted, they must identify it and request an accessible export instead of claiming it was understood.

These files express business intent. Current UiPath source remains authoritative for existing technical behavior. Preserve the original intake files when deriving `.ai/context/` documents.

Never store passwords, tokens, credential values, sensitive production data, or active session information here.
