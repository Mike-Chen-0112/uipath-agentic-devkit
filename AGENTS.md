# Project

- Name: RPA AI DevKit
- Purpose: Provide a Development-only UiPath automation kit for GitHub Copilot in VS Code.
- Project type: Central DevKit source and bot-payload generator, not a business UiPath project.
- Version: See `VERSION`; keep source and payload version references aligned.

# Entry Points

- `scripts/Install-RpaAiDevKit.ps1` - install the generated bot payload.
- `scripts/Export-RpaAiDevKit.ps1` - build the bot payload and ZIP.
- `scripts/Activate-RpaAiDevKit.ps1` - activate an installed bot.
- `scripts/Test-Prerequisites.ps1` - check local prerequisites.
- `scripts/ExecutionState.ps1` - persist stage timings, repair limits, and performance reports for installed bots (no time budget).
- `tests/Test-DevKit.ps1` - deterministic regression suite.

# Architecture

- Four existing roles coordinate work: RPA Coordinator, RPA Developer, RPA Documentation, and RPA Auditor.
- The Coordinator owns the Change Contract, Impact Set, approval, authoritative Executable Change Plan, and R0-R3 risk classification.
- The Developer verifies and implements the approved plan, prepares dependencies, validates, and returns evidence.
- The Documentation Agent handles targeted human-facing documentation only when documentation impact is `HUMAN_DOCS`.
- When routed, the Auditor independently reviews the diff and evidence and returns `PASS`, `REWORK`, `ESCALATE_TO_FULL_AUDIT`, or `BLOCKED`; eligible no-audit work completes with Developer self-review instead.
- There is no time budget. Execution state records wall, active, setup, and user-wait time for reporting only; elapsed time never stops work or skips a gate. Repair loops are capped at three.
- Setup is self-healing and prompt-free: activation installs missing user-scoped tools and the .NET runtime, retries failed installs, rebuilds a broken graph, and restores existing project dependencies. Git is optional. The Coordinator's single development approval is the only user prompt.

# Key Workflows

- `.github/agents/` -> role prompts and handoff behavior.
- `.github/instructions/` -> reusable governance, dependency, UI, output, evidence, and documentation procedures.
- `.github/skills/rpa-standards/` -> shared UiPath engineering standards.
- `scripts/` -> installation, activation, validation, Graphify wrappers, and release tooling.
- `templates/` -> generated bot context, evidence, and payload starter files.
- `distribution/payload-manifest.json` -> payload source, destination, and ownership contract.

# Applications

- VS Code and GitHub Copilot are the agent-facing development surface.
- UiPath CLI, Graphify, PowerShell, and Git support setup and validation.
- Business applications are defined by each installed bot, not by this central repository.

# Dependencies

- Windows PowerShell 5.1 or PowerShell 7+, VS Code with GitHub Copilot. Git is optional for bots (change review falls back to file snapshots).
- Official UiPath CLI is the default toolchain; pinned local-only Graphify is installed only on request for unresolved impact analysis.
- Runtime readiness uses the actual compiler runtimeconfig and architecture, not an assumed .NET version. `Initialize-UiPathRuntime.ps1` verifies existing frameworks and, by default, installs a missing runtime for the current user from official Microsoft sources only, without elevation or global PATH changes (`-NoInstall` to verify only). The runner passes a verified fresh local runtime record into the child .NET environment. Runtime availability, compiler startup, and actual restore/build are separate checks.
- Compatibility distinguishes project generator metadata from the actual installed or supplied authoring host and preserves valid package pins. For UI Automation, the exact package's official nuspec minimum Studio requirement takes precedence over numeric release lines: `MET` permits cross-release selection without reviewed JSON; `NOT_MET` blocks even same-line or reviewed selections. Missing metadata remains `UNKNOWN` and retains conservative release-line behavior; manual reviewed schema1 JSON matching actual `studioVersion`, `cliVersion`, exact package version, and an official HTTPS `docs.uipath.com` reference remains available. The helper hashes metadata into compatibility evidence and its fingerprint. A URL or unsupported boolean alone is not proof; selection does not replace installation, build, or live UI capture.
- Central changes use PowerShell and Git; business bot dependencies belong in the installed bot project.

# Orchestrator Resources

- No Central DevKit Orchestrator queues, assets, connections, or Production resources are owned here.
- Bot-specific resources belong in the bot's `.ai/context/orchestrator-resources.md` and current project configuration.

# Development Constraints

- Development resources only. Never access, modify, deploy to, or start Production resources.
- Never store credentials, tokens, secret values, sensitive page content, or unnecessary screenshots in source, context, prompts, logs, or evidence.
- Do not create or remove agents. Preserve the four-role workflow and PASS/REWORK/BLOCKED semantics.
- Graphify remains local-only, code/XAML-only, query-logging-disabled, and governed by its existing wrappers.

# Conventions

- Keep changes minimal, source-controlled, and evidence-backed.
- A provably non-behavioral R0 change defaults to `AUDIT_MODE: NONE`; an eligible localized R1 change may also skip independent audit after the stricter Developer gate and self-review. Other R1 work defaults to `LIGHT`; R2-R3 retain mandatory independent audit and full applicable validation. See `.github/instructions/risk-routing.instructions.md`.
- Treat current source as authoritative over generated graph or curated context.
- Use the approved Change Plan as the Developer handoff; report material `PLAN_DEVIATION`.
- One approval covers continuation from the failed gate through implementation, capture, tests, output QA, and required audit; environment repair never needs approval. Blocked installation, authentication, UI access, licensing, or safety restrictions still require `BLOCKED`. Approval does not bypass gates or permit more than three repair loops.
- `ExecutionState.ps1 -Action EnvironmentStart -Reason <scope>` / `EnvironmentEnd -PhaseStatus PASS|BLOCKED` optionally record setup time; they are timing markers only. See `docs/DEPENDENCY-SETUP-PROTOCOL.md`.
- Reuse valid `AGENTS.md` context and load detailed context only for topics in the Change Plan and Impact Set.
- Keep detailed procedures in scoped instruction files and specialized official UiPath skills.
- Project Mapper is default. Graphify is optional and on-demand, not a prerequisite for scaffolding, activation or fast context; dependency restore is reused when its fingerprint matches.
- Shared `SourceFingerprint.ps1` provides schema-versioned executable, documentation, and graph-configuration fingerprints; `Invoke-DevKitCommand.ps1` records command duration, exit status, timeout, and output.

# Detailed Documentation

- Documentation routing: `.github/instructions/documentation.instructions.md`
- Architecture template: `templates/bot-context/architecture.md`
- Business rules template: `templates/bot-context/business-rules.md`
- Applications template: `templates/bot-context/applications.md`
- File journey template: `templates/bot-context/file-journey.md`
- Orchestrator template: `templates/bot-context/orchestrator-resources.md`
- Tests template: `templates/bot-context/test-catalog.md`
- Known issues template: `templates/bot-context/known-issues.md`
- Human documentation template: `templates/bot-docs/docs/Bot-Documentation.md`
- Release history: `docs/CHANGELOG.md`
