# RPA AI Dev Kit v0.11.8

This repository contains an AI-assisted UiPath Development kit. Production access and deployment are not permitted.

## First-time setup

1. Open PowerShell in this bot repository. Windows PowerShell 5.1 and PowerShell 7+ are supported; administrator access is not required.
2. Run the one activation command:

   ```powershell
   ./.rpa-ai/scripts/Activate-RpaAiDevKit.ps1
   ```

   It discovers tools already installed in your Windows profile. When needed, it downloads verified portable Node.js/npm and `uv`, installs the UiPath CLI/skills and pinned Graphify for the current user, and runs diagnostics. No administrator access or `PATH` change is required.

3. Wait for the **RPA AI DEV KIT IS READY** banner.
4. Open this repository in VS Code and select **RPA Coordinator** in Copilot Chat.
5. Give one bug-fix, change, or new-development prompt. `Requirements/` is the canonical human-owned workspace after scaffolding; `.ai/intake/` remains available for pre-scaffold material.
6. Review the Coordinator's recommended approach and single combined Development proposal, then approve it once. The Coordinator freezes one authoritative Executable Change Plan, risk level, `AUDIT_MODE`, and `AUDIT_REASON`; the Developer verifies that plan, validates the change, and reports any material `PLAN_DEVIATION`.
7. Documentation impact is classified as `NONE`, `CONTEXT_ONLY`, or `HUMAN_DOCS`; the Documentation Agent runs only for `HUMAN_DOCS`. R0 and eligible localized R1 changes may complete with `AUDIT_MODE: NONE` after all Developer gates and self-review pass; `LIGHT` and `FULL` modes invoke the Auditor.
8. Each task starts `.rpa-ai/scripts/ExecutionState.ps1`, which persists reconciled wall, active, explicit user-wait, and external-interruption time; stages; compact command evidence; and repair-loop count. There is no time budget. Detailed Developer events remain in `.ai/evidence/developer-events.jsonl`, with only its path/hash/size and timing totals referenced by execution state.
9. Validation remains risk-proportional. Eligible textual R0 and localized non-structural R1 changes may skip cold native diagnostics only with complete safety facts. New/generated/structural/serialization-risk workflows run content-parsed `uip rpa get-errors`, and new or materially changed projects must pass the final `uip rpa build` before delivery. If those gates cannot run, delivery is blocked rather than reported as PASS.

`AGENTS.md` is the compact project context read first by agents. The Coordinator inventories `Requirements/`, reads `REQUIREMENTS.md` as its structured entry point, and opens supporting files only when relevant. It never silently modifies human-owned requirement material. Detailed `.ai/context/` files are loaded only when relevant to the approved Change Plan and Impact Set.

Recommended when available and approved: **GPT-5.6 Luna**, **High** reasoning, **200K** context for routine changes, and **1M** for new or complex bot development.

## Existing UiPath project

1. Keep the existing `project.json`, workflows, configuration, and repository documentation.
2. Select **RPA Coordinator** and describe the business outcome, current failure, and expected result in plain language.

The Coordinator maps the project before broad source discovery, and the Developer performs targeted changed-workflow sanity before the full validation sequence.

## New bot

1. Put the available process documents in `.ai/intake/`.
2. Select **RPA Coordinator** and ask it to read the intake, create a Process or REFramework project, and implement the Development-safe requirement.

The agent must create the UiPath project with official `uip rpa` scaffolding. It must not hand-write `project.json` or starter XAML. Successful initialization creates `Requirements/REQUIREMENTS.md` when missing and preserves anything already present there.
New-bot routing checks for `project.json` first, defers repository impact analysis and Graphify discovery until the scaffold is stable, and performs one final graph synchronization after implementation.

## Boundaries

- Development resources only. Production access and deployment are outside this kit.
- Do not store credentials, tokens, or secret values in intake, context, prompts, screenshots, graph data, or evidence.
- `Requirements/` is human-owned; agents may read it but cannot silently modify, move, delete, or generate artifacts in it. `.ai/intake/`, `.ai/context/`, `.ai/evidence/`, `.ai/feedback/`, UiPath source, and bot configuration are bot-owned.
- Files listed as managed in `.rpa-ai/kit-manifest.json` are read-only during bot development.
- Graphify runs locally in code-only mode. Approved downloads may come in; bot content must not leave through Graphify or another third-party library.

Bot documentation is kept in `README.md`, `docs/Bot-Documentation.md`, `docs/Testing.md`, and `docs/CHANGELOG.md`.

See `.rpa-ai/docs/TROUBLESHOOTING.md`, `.rpa-ai/docs/PLATFORM-SUPPORT.md`, and `.rpa-ai/docs/PILOT-SCENARIOS.md` for recovery, support, and trial workflows.
