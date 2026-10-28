# RPA AI Dev Kit v0.12.2

Create or change UiPath automations through GitHub Copilot in VS Code. The same setup supports new bots and existing UiPath projects.

> This release is intended for Development pilots. It is not approved for Production deployment or Production resource access.

## Start here

### 1. Check the workstation

Minimum requirements: Windows, Windows PowerShell 5.1 or PowerShell 7+, VS Code with GitHub Copilot, and internet access to the official package download sites. Git is optional but recommended.

Administrator access and system `PATH` changes are not required. Setup installs everything else (Node.js/npm, UiPath CLI, UiPath skills, `uv`, and Graphify) in your Windows user profile and restores your project's dependencies; a missing .NET runtime is installed the same way when the compiler first needs it. It retries and repairs common failures on its own; you are not asked to approve any setup step.

The check is optional. To run it, open PowerShell in this cloned repository and run:

```powershell
./scripts/Test-Prerequisites.ps1
```

### 2. Install and activate

There are two ways to install the kit. Choose the one that matches what you have.

#### Option A: You cloned this repository

Open PowerShell in the cloned `uipath-agentic-devkit` folder. Run this command and replace `C:\RPA\MyBot` with the folder for your bot:

```powershell
./scripts/Install-RpaAiDevKit.ps1 -TargetBotPath C:\RPA\MyBot
```

The bot folder can contain an existing UiPath project, or it can be an empty folder for a new bot. Run the same command again to upgrade; unchanged kit files are replaced automatically.

#### Option B: You have the ZIP file

1. Find `rpa-ai-devkit-bot-0.12.2.zip` in the `artifacts` folder.
2. Extract the ZIP into a temporary folder, not directly into the bot folder.
3. Open PowerShell in the extracted folder. Run this command and replace `C:\RPA\MyBot` with the folder for your bot:

```powershell
./.rpa-ai/scripts/Import-RpaAiDevKit.ps1 `
  -PayloadPath . `
  -TargetBotPath C:\RPA\MyBot
```

Wait for `RPA AI DEV KIT IS READY`. Resolve any reported `FAIL` before continuing.

### v0.12.2 lean scaffolding (optional)

A new bot can omit only the optional Humanizer and Caveman prose Skills (four files), while retaining required runtime, validation, safety checks and rollback:

```powershell
./scripts/Install-RpaAiDevKit.ps1 -TargetBotPath C:\RPA\MyBot -SlimPayload
```

Use `./scripts/Export-RpaAiDevKit.ps1 -SlimPayload` for a slim ZIP. Standard payload remains the compatibility default. Existing optional Skills are not deleted automatically on upgrade.

Official project creation provides `-Json` for future router integrations and uses summary telemetry by default; use `-TelemetryLevel Detailed` for per-step scaffold and Requirements events:

```powershell
& ./.rpa-ai/scripts/New-RpaProject.ps1 -ProjectName InvoiceBot -ProjectType Process -TargetFramework Windows -Json
```

A failed scaffold still throws, preserves safety gates, and never emits a success JSON object.

### 3. Make one request

After the ready banner appears, normal users interact only with **RPA Coordinator**:

1. Open the bot repository in VS Code.
2. For a new bot, optionally place pre-scaffold material in `.ai/intake/`; after scaffolding, use the project-root `Requirements/` workspace.
3. Open Copilot Chat and select **RPA Coordinator**.
4. Describe the business outcome in plain language.
5. Approve the Coordinator's single Development proposal. That is the only question you are asked.

Example for an existing bot:

> Change the process so invalid employee IDs are recorded as business exceptions, valid records continue processing, and the result workbook contains a readable rejection reason. Use Development resources only.

Example for a new bot:

> Read the files in `.ai/intake/`. Create a Windows REFramework project from an Official UiPath template, implement the described process using Development resources only, validate it, and return audited evidence.

The Coordinator checks for a newer Dev Kit release, presents one solution when the implementation is clear and up to three only for genuine architectural trade-offs, then handles dependency setup, UI target capture, implementation, impact-based documentation, validation, output checks, and risk-based audit routing without further prompts. Environment problems such as a missing runtime, failed restore, or broken graph are repaired automatically (up to three repair loops). R0 and eligible localized R1 work may finish after deterministic proof and Developer self-review; `LIGHT` and `FULL` modes invoke the Auditor. There is no time budget: each task records timing under `.ai/evidence/execution-state.json` for reporting only and keeps working until it passes or hits a genuine blocker. Localized work starts from a deterministic, freshness-guarded Developer context package containing only the selected workflow neighborhood, activity locations, and compact graph references; raw XAML, the complete Project Map, and the full graph remain authoritative/on-demand fallbacks. Browser/UI work resolves project-local validated targets before discovery, checks selector quality and installed capability evidence, separates web DOM from native dialogs, and advances through a bounded fallback hierarchy without repeated equivalent exploration. One-call Developer validation and completion helpers own structural validation, unchanged policy gates, compact evidence/handoff creation, final fingerprints, and atomic state completion, while repository-visible context and expansions remain profiled without storing prompt or source content. Unavailable host/model internals are explicitly unestimated. Solution selection is not an approval gate. Final outcomes are `PASS`, `REWORK`, or `BLOCKED`.

### Documentation model

`AGENTS.md` is the compact reusable project context read first by agents. `Requirements/` is the canonical human-owned source for business requirements and supporting evidence: the Coordinator inventories it, reads `REQUIREMENTS.md` as the structured entry point, and loads supporting files selectively. Agents never silently change requirement files. Detailed `.ai/context/` files are loaded only for topics relevant to the Change Plan and Impact Set. Documentation impact is proportional to the change: `NONE` requires no documentation work, `CONTEXT_ONLY` updates `AGENTS.md` when stable agent-facing facts change, and `HUMAN_DOCS` invokes the Documentation Agent for targeted human-facing sections.

### What activation handles

Activation verifies managed files; installs missing portable Node.js/npm, UiPath CLI, `uv`, and Graphify tools in the current user profile (retrying once on failure); installs UiPath Copilot skills; reuses, refreshes, or rebuilds the graph for existing projects; restores existing project dependencies; defers graph extraction for project-less new bots; and runs diagnostics.

### Optional response and prose skills

The payload includes two on-demand skills:

- **Humanizer** improves user-facing prose without changing claims, code, metadata, data, or link targets.
- **Caveman** reduces conversational filler. Use `lite` or normal mode for RPA work; keep safety warnings, approvals, evidence, exact errors, commands, and generated business content fully readable.

The Dev Kit does not install Caveman's proxy, hooks, telemetry, or always-on Copilot instruction file. The proxy is a separate component with different licensing and data-storage behavior. Measure provider-billed usage before enabling any runtime compression for a specific environment.

Graphify is mandatory and local-only. Approved downloads may enter the workstation, but bot source, graph data, business content, and generated files must not leave through Graphify or another third-party library.

### Safety

- Use Development resources only.
- Never include credentials, tokens, or secret values in prompts, files, screenshots, graph output, or evidence.
- Do not edit files marked `managed` in `.rpa-ai/kit-manifest.json` inside a bot.
- A file change alone is not a pass; applicable validation must succeed, and independent audit is required whenever `AUDIT_MODE` is `LIGHT` or `FULL`.

For common setup failures, see [Troubleshooting](docs/TROUBLESHOOTING.md).
For repeatable wall-clock, active-time, cache, command, and audit measurements, see [Performance Benchmark](docs/PERFORMANCE-BENCHMARK.md).

The Coordinator may also inspect a bot and suggest changes without implementing them. The single approval gate is temporary policy and can be removed centrally after sufficient trust is established.

<!-- markdownlint-disable MD033 -->
<details>
<summary><strong>Detailed reference for maintainers and advanced users</strong></summary>
<!-- markdownlint-enable MD033 -->

## How distribution works

This repository is the maintained source kit. Users should copy the generated **bot payload**, not the complete source repository, into each bot repository.

The payload contains only bot-relevant files:

```text
.github/agents/                 RPA Coordinator, Developer, Documentation, and Auditor
.github/instructions/           development and evidence rules
.github/skills/rpa-standards/   shared RPA engineering standards
AGENTS.md                       compact reusable agent context
.ai/intake/                     human-created bot source material
.ai/context/                    optional curated bot context
.ai/evidence/                   evidence template and run evidence
.ai/feedback/                   bot-owned reusable Dev Kit feedback
.rpa-ai/scripts/                bootstrap, validation, and graph helpers
.rpa-ai/validation/             validation and version policy
.rpa-ai/local/                  machine-specific tool, version, and Outlook capability state
.rpa-ai/docs/                   detailed bot-local protocols
.graphifyignore                 managed local-only graph scope
.graphifyrc                     managed Graphify project settings
START-HERE.md                   short instructions inside the bot repo
```

Central tests, backlog, scorecard, source templates, release metadata, and maintainer documentation are not included in the payload.

For file-handling processes, `.ai/context/file-journey.md` is the bot-owned lifecycle map for logical artifacts and their success, failure, cleanup, retention, and deletion paths. It is separate from the generated Graphify output and must not contain file contents, credentials, tokens, or unnecessary sensitive data.

Copying the complete source repository into a bot is not inherently destructive, but it is not the supported distribution contract. It adds central-only material and makes upgrades harder to reason about.

## Prerequisites

Required for the standard flow:

- Windows;
- Windows PowerShell 5.1 or PowerShell 7+;
- VS Code with GitHub Copilot;
- outbound HTTPS access to the official Node.js, GitHub, npm, Python, and Microsoft .NET package endpoints used during setup.

Git is optional. Without it, change review uses file snapshots and kit update checks are skipped.

Activation installs missing portable Node.js/npm, official `@uipath/cli`, `uv`, and pinned Graphify packages in the developer's Windows user profile, then restores the project's dependencies. A missing .NET runtime is installed in the user profile when the compiler first needs it. These tools do not need to be on `PATH`.

Check the workstation:

```powershell
./scripts/Test-Prerequisites.ps1
```

Current UiPath coding-agent tooling can use a headless Studio host for normal project creation, authoring, validation, build, and execution. UiPath Studio Desktop is still needed for specific interactive designer operations documented by UiPath, but it is not the default authoring surface for this kit.

## Build the bot payload

From this central repository:

```powershell
./scripts/Export-RpaAiDevKit.ps1 `
  -OutputDirectory ./artifacts `
  -Force
```

This produces:

```text
artifacts/rpa-ai-devkit-bot-0.12.2/
artifacts/rpa-ai-devkit-bot-0.12.2.zip
```

The payload is assembled from [distribution/payload-manifest.json](distribution/payload-manifest.json). `.rpa-ai/kit-manifest.json` inside the payload records the release version, ownership mode, and SHA-256 hash of every source payload file. The generated manifest itself is the root metadata document and does not self-hash.

## Path A: Existing UiPath bot

Use this path when the bot repository already contains `project.json`.

### Manual copy

1. Review whether the bot already has `.github/copilot-instructions.md`, custom agents, instructions, or an RPA standards skill.
2. Copy the payload contents into the bot project root.
3. Preserve existing bot-owned files under `.ai/intake/`, `.ai/context/`, and `.ai/evidence/`.
4. If managed customization files already exist, use the import helper instead of deciding overwrites manually.
5. Activate the Dev Kit from the bot root:

```powershell
./.rpa-ai/scripts/Activate-RpaAiDevKit.ps1
```

Activation discovers or installs the user-scoped UiPath CLI, installs the official UiPath skills locally, verifies managed files, installs/verifies Graphify, reuses or refreshes an existing-project graph, defers project-less new-bot extraction, and runs diagnostics.

### Checked import

From the central repository:

```powershell
./scripts/Import-RpaAiDevKit.ps1 `
  -PayloadPath ./artifacts/rpa-ai-devkit-bot-0.12.2 `
  -TargetBotPath C:\RPA\MyBot
```

The importer:

- verifies payload hashes;
- adds missing files;
- preserves bot-owned intake, context, evidence, and feedback;
- reports managed-file conflicts instead of silently replacing them;
- writes the installed payload metadata only after preflight succeeds;
- verifies or installs the pinned Graphify package locally;
- reuses or refreshes the bot-specific graph for an existing project; project-less new bots record deferred graph extraction until stable finalization.

The existing compatibility command remains available:

```powershell
./scripts/Install-RpaAiDevKit.ps1 -TargetBotPath C:\RPA\MyBot
```

## Path B: New bot repository

Use this path when no UiPath project exists yet.

1. Create an empty repository for the bot.
2. Copy or extract the bot payload into its root.
3. Place all available manually created process material under `.ai/intake/`.
4. Activate the Dev Kit when the ZIP was extracted manually:

```powershell
./.rpa-ai/scripts/Activate-RpaAiDevKit.ps1
```

1. Resolve any `FAIL` reported by activation.
2. Open the bot repository in VS Code.
3. Select **RPA Coordinator** in Copilot Chat.
4. Describe the bot to create.

Example:

> Read every accessible file in `.ai/intake/`. Create a Windows REFramework project for this process using an Official UiPath template, then implement the Development-safe automation and return evidence.

The Coordinator asks only for material choices not already resolved by the prompt or intake:

- Process or REFramework;
- Windows or Portable.

Unless explicitly requested otherwise, the technical defaults are XAML workflows with Visual Basic expressions.

The Developer calls the bot-local bootstrap script, which:

1. detects the installed UiPath CLI command generation;
2. uses `uip rpa init` or the compatible `uip rpa create-project` surface;
3. searches configured feeds for an Official REFramework template when requested;
4. generates the project in an isolated sibling staging directory;
5. validates `project.json` and generated workflows;
6. rejects collisions before transferring the scaffold into the bot root;
7. records scaffold provenance in `.ai/evidence/project-scaffold.json`;
8. creates or reuses the human-owned `Requirements/REQUIREMENTS.md` entry point without overwriting content.

The script can also be run directly when all choices are already known:

```powershell
./.rpa-ai/scripts/New-RpaProject.ps1 `
  -ProjectName EmployeeStatusBot `
  -ProjectType REFramework `
  -TargetFramework Windows
```

The kit never hand-writes a starter `project.json` or REFramework XAML.

## Requirements and pre-scaffold intake

Every newly initialized blank project receives `Requirements/REQUIREMENTS.md`. `Requirements/` is the canonical location for human-provided business requirements, screenshots, diagrams, and sample/supporting files. Existing mature projects are not given an empty folder automatically, but an existing Requirements workspace is discovered and used. `.ai/intake/` remains the legacy/pre-scaffold location for material supplied before `project.json` exists. For file-handling processes, maintain the logical artifact lifecycle in `.ai/context/file-journey.md`.

One consolidated document is preferable when practical, but the folder may contain approved Markdown, text, Word, PDF, Excel, CSV, screenshots, or supporting samples. Useful content includes:

- purpose and expected business outcome;
- trigger, schedule, inputs, and outputs;
- applications and approved Development URLs;
- process steps, decisions, and business rules;
- exception and retry expectations;
- queue, asset, credential, and configuration names without secret values;
- Development test cases and acceptance criteria;
- Process or REFramework preference.

The Coordinator inventories filenames and types first, reads `REQUIREMENTS.md`, and inspects only relevant supporting files. An unsupported file remains untouched and is reported when relevant; empty optional template fields do not automatically block work. Screenshots are requirement evidence rather than selectors, and example files are not runtime inputs unless explicitly identified as such.

For business intent, precedence is the current explicit prompt, Requirements material, other authoritative project documentation, implementation evidence, then inference. Conflicts between human artifacts are surfaced rather than silently resolved or rewritten. Current UiPath source remains authoritative for actual technical behavior. Everything under Requirements is human-owned; agents do not silently edit, delete, rename, move, or place generated artifacts there.

## Prompt-based changes

For an existing bot, select **RPA Coordinator** and describe the business outcome rather than prescribing XAML details.

Example:

> Change the process so invalid employee IDs are recorded as business exceptions, valid records continue processing, and the result workbook contains a readable rejection reason. Use Development resources only.

The agent chain is:

```text
Business request
      |
RPA Coordinator
      |
RPA Developer
      |
RPA Documentation
  |
RPA Auditor
   /      \
REWORK    PASS
```

The standard lifecycle is:

```text
Understand requirement
-> check project.json and start execution tracking
-> verify managed Dev Kit integrity, map an existing project, and reuse/refresh its graph
-> retrieve intake/context and current source, or read new-bot intake only
-> analyze impact
-> restore/install/verify dependencies
-> capture live UI targets when required
-> develop
-> run changed-workflow sanity, risk-based diagnostics, build/analyzer, and targeted tests
-> inspect generated business outputs when required
-> audit
-> refresh the graph and recheck managed integrity
-> PASS / REWORK / BLOCKED
```

## Evidence and completion

A file change alone is not completion. The final result must include applicable evidence for:

- requirement and acceptance criteria;
- managed Dev Kit integrity and bot-local graph freshness;
- payload and scaffold integrity for a new bot;
- dependency setup before behavioral authoring;
- browser target capture before UI authoring;
- validation commands and exit status;
- diagnostics required/executed decision, reason, complete change facts, duration, and detailed validation timing;
- compact execution-state size/output-reference evidence;
- relevant Development execution;
- actual generated-output data and readability checks;
- explicit `AUDIT_MODE` and `AUDIT_REASON`, plus an independent Auditor verdict when `LIGHT`/`FULL` is used or a Developer escalation requires it;
- assumptions and residual risks.

Untouched output from an official UiPath scaffold may be classified `GENERATED_SCAFFOLD_ONLY`. As soon as generated behavior, dependencies, arguments, selectors, or project wiring are edited, the work becomes `BEHAVIORAL_CHANGE` and normal validation applies.

Final outcomes are `PASS`, `REWORK`, or `BLOCKED`.

## Upgrades

For an unchanged managed installation, apply a future payload with:

```powershell
./scripts/Import-RpaAiDevKit.ps1 `
  -PayloadPath ./artifacts/rpa-ai-devkit-bot-NEW_VERSION `
  -TargetBotPath C:\RPA\MyBot `
  -Upgrade
```

If a managed file was edited locally, import stops and reports a conflict. Review and merge the change. Use `-OverwriteManaged` only when replacement has been explicitly reviewed.

Bot-owned intake, context, evidence, feedback, UiPath source, and configuration are never upgrade targets.

## Mandatory local Graphify

Graphify is bot-local and cache-first. Existing projects reuse or refresh the graph during planning when the source fingerprint requires it; project-less new bots defer graph extraction until stable finalization. After final source changes, refresh once when the content fingerprint differs. When `AUDIT_MODE` is `LIGHT` or `FULL`, the Auditor consumes that final snapshot; for `AUDIT_MODE: NONE`, the Coordinator/Developer use it for completion. Auditor PASS alone never requires another refresh. Current repository source always wins when the graph disagrees.

Graphify processes code/XAML locally. The wrappers force code-only extraction without clustering, disable query logging, and remove known cloud/model credentials from child processes. Intake, context, evidence, documents, Office files, media, and generated business output are excluded.

Approved package and tool data may come into the workstation. Bot source, graph data, business content, and generated artifacts must not leave through Graphify or another third-party library. See [docs/GRAPHIFY.md](docs/GRAPHIFY.md).

## Managed core and feedback

Files marked `managed` in `.rpa-ai/kit-manifest.json` are centrally controlled and immutable during bot development. This includes the agents, instructions, shared skill, validation policy, and Dev Kit scripts. `Test-ManagedFileIntegrity.ps1` enforces their hashes.

Do not patch a managed file inside one bot to work around a product limitation. Record a reusable, non-sensitive proposal in `.ai/feedback/dev-kit-improvements.md` and share it with the Dev Kit maintainers.

## Detailed safety policy

- Development resources only.
- No Production jobs, deployments, servers, or Orchestrator mutations.
- Never store credentials, tokens, session values, or secret data in source, intake, context, graph output, screenshots, prompts, or evidence.
- Do not guess browser selectors when approved live target capture is available.
- Do not implement behavioral code before required dependencies are available.
- Do not claim PASS because files were generated or copied.

## Maintainer documentation

- [Setup manual](docs/SETUP.md)
- [Methodology](docs/METHODOLOGY.md)
- [Dependency protocol](docs/DEPENDENCY-SETUP-PROTOCOL.md)
- [UI capture protocol](docs/UI-CAPTURE-PROTOCOL.md)
- [Output quality protocol](docs/OUTPUT-QUALITY-PROTOCOL.md)
- [Smoke test](docs/SMOKE-TEST.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Platform support](docs/PLATFORM-SUPPORT.md)
- [Example prompts](examples/EXAMPLE-PROMPTS.md)
- [Pilot scenarios](examples/PILOT-SCENARIOS.md)
- [Improvement backlog](docs/IMPROVEMENT-BACKLOG.md)
- [Technology sources](docs/SOURCES.md)

## Release status

v0.12.2 is a controlled Development pilot for existing-bot fixes and greenfield Process/REFramework development. Setup is self-healing and prompt-free, and there is no execution time budget. UI Automation compatibility uses the exact package's declared minimum Studio requirement before release-line matching; unmet minimums still block, including those discovered during restore. Existing pins, risk-based Fast Lane behavior, capture requirements, and final-build delivery gates remain in place. Deterministic repository tests do not replace workstation pilots. Real UiPath CLI creation, native diagnostics/build, VS Code custom-agent discovery, live browser capture, pinned Graphify installation, and representative Development executions must be recorded as passed or `NOT_RUN`; they must never be inferred.

<!-- markdownlint-disable MD033 -->
</details>
<!-- markdownlint-enable MD033 -->
