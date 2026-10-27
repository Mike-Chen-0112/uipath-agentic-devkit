# Project

- Name: Set from the current bot project and `project.json`.
- Purpose: Record only stable, high-value facts needed to start agent work.
- UiPath project type: Process / REFramework / Library / Other.

# Entry Points

- `Main.xaml` or the current project entry point.
- Add other stable entry points only when they matter to routine work.

# Architecture

- Architecture: Record the current source-verified architecture.
- Transaction source: Record only when applicable.
- Major components: Record stable workflow groups and shared components.

# Key Workflows

| Workflow | Purpose |
|---|---|
| `Main.xaml` | Record the verified entry-point purpose. |

# Applications

- Record each external application and its business purpose only when stable and relevant.

# Dependencies

- Record important project dependencies and external runtimes from the current project.
- Do not use this file as a substitute for the dependency manifest or lockfile.

# Orchestrator Resources

- Record important queues, assets, connections, and other resources without values or secrets.

# Development Constraints

- Development resources only; Production access and deployment are prohibited.
- `Requirements/` is human-owned business intent and evidence. Inventory it first, use `REQUIREMENTS.md` as its structured entry point, inspect supporting files selectively, and never silently modify or generate artifacts inside it.
- Follow `.github/instructions/browser-ui.instructions.md` for browser/UI work and live target capture.
- Use Chrome by default for new browser activity unless the requirement or target application explicitly requires another browser. Resolve logical targets through `.rpa-ai/scripts/Resolve-UiTarget.ps1` before exploration or implementation: compatible live-validated registry target, Object Repository, strict/DOM, anchor, fuzzy, semantic DOM, semantic image/CV, image, then coordinates only as a last resort. Capability detection is local and never upgrades packages. Prefer UiPath UI Automation activities and resolved descriptors over code blocks; document any exception.
- Do not store credentials, tokens, sensitive page content, or unnecessary screenshots.

# Conventions

- Reuse current Config, naming, logging, exception, and retry conventions.
- Treat current workflow and project source as authoritative.
- For business intent, use current explicit instructions, `Requirements/`, other authoritative documentation, implementation evidence, then inference. Surface conflicts; optional empty fields do not block by themselves. Screenshots are not selectors and examples are not runtime inputs unless explicitly designated.
- Load detailed context only when the Change Plan and Impact Set make that topic relevant.
- Record `RISK_LEVEL`, `AUDIT_MODE`, and `AUDIT_REASON`; eligible R0 work uses its applicable validation, behavioral R1 `NONE` work requires complete Developer validation and self-review, while R2/R3 and triggered escalations require independent audit.
- Start `.rpa-ai/scripts/ExecutionState.ps1` for every task. Use its persisted wall/active/user-wait/external-interruption clocks, stage and Developer phase intervals, compact command evidence, run history, and three-loop repair cap; there is no time budget, and elapsed time never stops work. Use `.rpa-ai/scripts/New-DeveloperContextPackage.ps1` for the scoped, freshness-guarded Developer handoff and on-demand source expansion; raw XAML remains authoritative and full source/graph/map access remains available on fallback. Profile only repository-visible Developer inputs with `.rpa-ai/scripts/Get-DeveloperContextProfile.ps1`; label host/model internals `NOT_INSTRUMENTABLE` when authoritative timestamps are unavailable.
- Use `.rpa-ai/scripts/SourceFingerprint.ps1` for shared executable/documentation/graph-configuration freshness and `.rpa-ai/scripts/Invoke-DevKitCommand.ps1` for supported long-running commands.
- Use `.rpa-ai/scripts/Write-DeveloperEvent.ps1` for source/edit/UI/package operations not already instrumented, and route subprocesses through `.rpa-ai/scripts/Invoke-DevKitCommand.ps1`; never store raw XAML, DOM, screenshots, or large output in the ledger. Use `.rpa-ai/scripts/Invoke-DeveloperValidation.ps1` for one coherent, risk-proportional validation checkpoint: cheap structure/package/enum checks, content-parsed native diagnostics when serialization risk requires them, then the required final build. Missing, incomplete, higher-risk, or uncertain facts run diagnostics; valid low-risk Fast Lane behavior remains. Use `.rpa-ai/scripts/Complete-DeveloperRun.ps1` once for deterministic evidence, runtime breakdown, final fingerprints, delivery-state enforcement, and compact next-role handoff.
- For an existing bot, use `.rpa-ai/scripts/Get-UiPathProjectMap.ps1 -Json` as compact structural navigation before broad search or raw XAML reading. Treat the map as a hint and current XAML as authority; expand when invokes are unresolved/dynamic or evidence requires it.
- For a new bot, check `project.json` before repository analysis and defer Graphify until the stable finalization step. For an existing bot, reuse Graphify when the source fingerprint is unchanged.

# Detailed Documentation

- Documentation routing: `.github/instructions/documentation.instructions.md`
- Architecture: `.ai/context/architecture.md`
- Business rules: `.ai/context/business-rules.md`
- Applications: `.ai/context/applications.md`
- File journey: `.ai/context/file-journey.md`
- Orchestrator: `.ai/context/orchestrator-resources.md`
- Tests: `.ai/context/test-catalog.md`
- Known issues: `.ai/context/known-issues.md`
- Human documentation: `docs/Bot-Documentation.md`
