# Setup Manual

This manual covers the v0.11.8 Development-pilot distribution model. The central repository produces a checked bot payload for each UiPath repository.

UI projects require no Target Registry setup. The first UI-target resolution creates `.devkit/ui-targets/registry.json`; non-UI projects do not create or load it. Capability detection reads existing project/package evidence and never upgrades packages or adds a login.

## 1. Workstation prerequisites

Required:

- Windows;
- Windows PowerShell 5.1 or PowerShell 7+;
- VS Code with GitHub Copilot;
- outbound HTTPS access to the official Node.js, GitHub, npm, Python, and Microsoft .NET package endpoints used during activation.

Git is optional. Without it, change review uses file snapshots and kit update checks are skipped.

Activation installs missing portable Node.js/npm, official `@uipath/cli`, `uv`, and pinned Graphify packages under the current user's profile, retries failed installs once, rebuilds a broken graph, and restores existing project dependencies. A missing .NET runtime is installed in the user profile when the compiler first needs it. It does not require administrator rights, a `PATH` change, or any approval prompt.

Check the core tools:

```powershell
./scripts/Test-Prerequisites.ps1
```

The check is non-mutating. Existing tools are verified when present; missing user-scoped tools are reported as items activation will install.

Normal coding-agent operations use UiPath's headless Studio host. Do not require Studio Desktop unless a documented interactive operation specifically needs it.

## 2. Export a release payload

From the central Dev Kit repository:

```powershell
./scripts/Export-RpaAiDevKit.ps1 `
  -OutputDirectory ./artifacts `
  -Force
```

Expected outputs:

```text
artifacts/rpa-ai-devkit-bot-0.11.8/
artifacts/rpa-ai-devkit-bot-0.11.8.zip
```

The exporter reads `distribution/payload-manifest.json`, verifies every source and destination, copies only bot-relevant files, and writes `.rpa-ai/kit-manifest.json` with release hashes.

Do not use the complete central source archive as the normal bot payload. It includes tests, backlog, source templates, release metadata, and maintainer documentation that bot repositories do not need.

## 3. Existing UiPath project

The target contains a valid `project.json` and opens or builds with the expected UiPath toolchain.

### Checked import

Use the central helper when possible:

```powershell
./scripts/Import-RpaAiDevKit.ps1 `
  -PayloadPath ./artifacts/rpa-ai-devkit-bot-0.11.8 `
  -TargetBotPath C:\RPA\ExistingBot
```

A fresh import:

- verifies every payload hash;
- copies missing managed and preserve-only files;
- records `.rpa-ai/kit-manifest.json`;
- appends the marked Dev Kit block to `.gitignore`;
- blocks conflicting managed files;
- activates the pinned local Graphify package and validates the initial bot graph.

### Manual copy

Manual payload copy is supported for a fresh bot repository when the destination paths do not already contain Copilot customizations.

Before copying, inspect these likely conflict paths:

```text
.github/copilot-instructions.md
.github/agents/
.github/instructions/
.github/skills/rpa-standards/
START-HERE.md
```

Do not replace existing bot-owned files under:

```text
.ai/intake/
.ai/context/
.ai/evidence/
```

If conflicts exist, use checked import or merge them deliberately.

### Compatibility installer

The existing-project command remains available and now uses the same payload manifest internally:

```powershell
./scripts/Install-RpaAiDevKit.ps1 -TargetBotPath C:\RPA\ExistingBot
```

## 4. New bot repository

The target repository has the payload but no `project.json`.

1. Create an empty repository for the bot.
2. Extract the contents of `rpa-ai-devkit-bot-0.11.8.zip` into its root.
3. Put any pre-scaffold documents in `.ai/intake/`; successful scaffolding creates the canonical human-owned `Requirements/REQUIREMENTS.md` workspace.
4. Activate the manually extracted payload:

```powershell
./.rpa-ai/scripts/Activate-RpaAiDevKit.ps1
```

1. Resolve any failure reported by activation.
2. Open the repository in VS Code.
3. Confirm **RPA Coordinator**, **RPA Developer**, **RPA Documentation**, **RPA Auditor**, and `rpa-standards` load in Chat Customizations diagnostics.
4. Select **RPA Coordinator** and provide a creation prompt.

Example:

> Read all accessible files in `.ai/intake/`. Create a Windows REFramework project from an Official UiPath template, implement the described process using Development resources only, validate it, and return audited evidence.

The Coordinator resolves:

- Process or REFramework;
- Windows or Portable;
- any unreadable or contradictory intake material.

XAML and Visual Basic are the defaults unless the request explicitly requires coded workflows or C# expressions.

## 5. Direct project bootstrap

When the choices are already known, the bot-local helper can be called directly.

Blank Process:

```powershell
./.rpa-ai/scripts/New-RpaProject.ps1 `
  -ProjectName InvoiceBot `
  -ProjectType Process `
  -TargetFramework Portable
```

REFramework:

```powershell
./.rpa-ai/scripts/New-RpaProject.ps1 `
  -ProjectName QueuePerformer `
  -ProjectType REFramework `
  -TargetFramework Windows
```

The helper probes local CLI help and supports:

- `uip rpa init` with `uip rpa templates search`; or
- `uip rpa create-project` with `uip rpa search-templates`.

For REFramework, exactly one Official match may be selected automatically. Multiple Official matches require an explicit package selection. Marketplace templates are never selected silently.

Scaffolding occurs in an isolated sibling staging directory because the payload already makes the bot repository non-empty. The helper verifies `project.json`, requires generated XAML, checks root collisions, transfers the scaffold, records `.ai/evidence/project-scaffold.json`, then creates or reuses `Requirements/REQUIREMENTS.md`. Existing content is never overwritten. Failed or colliding staging is preserved for diagnosis.

## 6. Requirements and intake documents

After scaffolding, put manually maintained business requirements and supporting evidence in project-root `Requirements/`. The lightweight `REQUIREMENTS.md` is the structured entry point; Markdown, text, Word, PDF, images, Excel, CSV, diagrams, and samples may sit beside it. Everything in the folder is human-owned and is never silently rewritten, moved, deleted, or used for generated output. `.ai/intake/` remains available for legacy/pre-scaffold input. Existing projects without Requirements are not modified.

Accepted in principle:

- Markdown and text;
- Word and PDF;
- Excel and CSV;
- approved screenshots and supporting samples.

The Coordinator inventories Requirements first and loads supporting files only when relevant. Unsupported files remain untouched and do not fail initialization. Empty optional fields do not block work; genuinely required gaps and conflicting human artifacts are surfaced. Screenshots remain evidence rather than validated selectors, and samples are not runtime inputs unless explicitly designated.

For business intent, precedence is the current explicit user instruction, Requirements material, other authoritative project documentation, implementation evidence, then inference. Current source remains authoritative for technical behavior.

Never include passwords, tokens, credential values, Production data, or active session information.

`.ai/context/` remains available for concise derived knowledge. New-bot users are not required to manually split their initial process description across all context templates.

### Compact context and documentation routing

`AGENTS.md` is the compact project context read first by agents and is reused across tasks. Detailed `.ai/context/` files are loaded only for topics named by the Change Plan and Impact Set. Documentation impact is proportional to the change: `NONE` requires no documentation work, `CONTEXT_ONLY` updates `AGENTS.md` when stable agent-facing facts change, and `HUMAN_DOCS` invokes the Documentation Agent for targeted human-facing sections.

## 7. Verify mandatory Graphify

From a copied payload:

```powershell
./.rpa-ai/scripts/Activate-RpaAiDevKit.ps1
./.rpa-ai/scripts/Refresh-BotGraph.ps1 -Mode Status
```

The payload pins the Graphify version and defaults to code/XAML local-only extraction. Query through:

```powershell
./.rpa-ai/scripts/Query-BotGraph.ps1 `
  -Question "What workflows and configurations affect transaction retry?"
```

Do not remove `.graphifyignore`, enable a remote semantic backend, or invoke hosted Graphify services. Package downloads may enter the workstation; bot content must not leave through Graphify or another third-party library.

## 8. Upgrade a bot

At Coordinator startup, the installed helper reads the canonical Azure DevOps repository recorded in the payload and discovers valid stable `vMAJOR.MINOR.PATCH` tags through Git. It continues silently when the check is unavailable. When a newer release exists, the user chooses whether to update or continue.

After explicitly choosing **Update**, use the bot-local helper:

```powershell
./.rpa-ai/scripts/Update-RpaAiDevKit.ps1 -TargetBotPath C:\RPA\ExistingBot -ConfirmUpdate
```

The updater checks managed integrity, checks out the selected tag, exports its payload, and reuses checked import with `-Upgrade`. It replaces only managed files that still match their previously installed hashes. It preserves bot-owned source, context, evidence, feedback, and documentation files, then activates and validates the resulting installation.

If activation or validation fails, the updater restores the previous managed files and reports whether rollback integrity passed. It does not start development against a partial installation.

The importer remains available for a reviewed local payload:

```powershell
./scripts/Import-RpaAiDevKit.ps1 `
  -PayloadPath ./artifacts/rpa-ai-devkit-bot-NEW_VERSION `
  -TargetBotPath C:\RPA\ExistingBot `
  -Upgrade
```

After reviewing a managed-file conflict, an explicit replacement is available:

```powershell
./scripts/Import-RpaAiDevKit.ps1 `
  -PayloadPath ./artifacts/rpa-ai-devkit-bot-NEW_VERSION `
  -TargetBotPath C:\RPA\ExistingBot `
  -OverwriteManaged
```

A v0.6 or manual installation without `.rpa-ai/kit-manifest.json` is treated as a legacy installation. Matching files are accepted; differing managed files require reviewed overwrite rather than guessed ownership. Automatic update requires checked installed metadata with the recorded canonical source repository.

## 9. Start development

For a behavioral change, establish a baseline:

```powershell
./.rpa-ai/scripts/Test-ManagedFileIntegrity.ps1
./.rpa-ai/scripts/Refresh-BotGraph.ps1 -Mode Update
./.rpa-ai/scripts/Validate-RpaProject.ps1
```

Then select **RPA Coordinator** and provide one business-level request. The agent chain presents solution options, obtains one development approval, then handles impact analysis, dependency setup, live UI capture when applicable, implementation, validation, Development execution, output QA when applicable, targeted documentation, and explicit risk-based audit routing.

The Coordinator's approved Executable Change Plan, risk level, and explicit audit mode are the authoritative Developer handoff. The Developer verifies that plan, records dependency state and deterministic validation results, and the Documentation Agent is invoked only when human-facing impact is confirmed. For `AUDIT_MODE: NONE`, eligible R0/R1 work completes only after the full applicable Developer validation pipeline and fixed self-review pass. `LIGHT` consumes the minimum plan, diff, Impact Set, direct callers, Audit Packet, and deterministic evidence; `FULL` preserves deep independent review. R2/R3 and every mandatory audit trigger remain independently audited.

## 10. Completion evidence

A new-bot result must include:

- payload version and integrity status;
- intake files read and any unreadable formats;
- project type, framework, expression language, and template selection;
- official scaffold provenance and generated files;
- whether generated behavior remained untouched;
- normal behavioral evidence if implementation followed scaffolding;
- audit mode and Auditor verdict when invoked, or Developer self-review evidence for a valid no-audit route.

Do not infer passes for unavailable checks. Record them as `NOT_RUN` with the reason and allow the Auditor to decide whether the result is blocked.

## 11. Copilot model guidance

When available and approved, use GPT-5.6 Luna with High reasoning. Use a 200K context window for routine bug fixes and focused changes. Use 1M for greenfield bots, broad cross-workflow impact, or genuinely complex development. This guidance is not hard-coded because Copilot model labels and enterprise availability can change.
