# Improvement Backlog

Use this as the peer-collaboration starting point.

## P0 — prove the loop

- [ ] Export the v0.11.2 payload and create one real blank Process plus one Official REFramework project on an approved Development workstation.
- [ ] Validate fresh copy into an existing bot and one managed-file upgrade conflict using real repositories.

- [ ] Verify `uip rpa uia --help` and the installed UiPath skill set expose the expected browser UI Automation agent capabilities on pilot workstations.
- [ ] Prove live target discovery for one click, one type, and one read/extract interaction on a Development test page.
- [ ] Prove `GENERATED_SCAFFOLD_ONLY` skips normal technical validation only for untouched Studio/official CLI output, then reverts to `BEHAVIORAL_CHANGE` after an edit.
- [ ] Prove `OUTPUT_QA_REQUIRED` opens/reads the actual generated Excel/CSV artifact and rejects file-exists-only evidence.
- [ ] Prove Excel QA catches clipped headers/values, leading-zero ID loss, unreadable date/number formats, and visible formula errors.

- [ ] Validate the four custom agents are detected in the organization's VS Code/Copilot configuration.
- [ ] Test Coordinator → Developer → Documentation → Auditor subagent delegation.
- [ ] Confirm automatic local UiPath skill installation and resulting skill discovery on company machines.
- [ ] Validate `Validate-RpaProject.ps1` against one Windows project and one older/legacy project if relevant.
- [ ] Decide approved Workflow Analyzer governance JSON and severity threshold.
- [ ] Define a safe, deterministic functional test path for the pilot bot.

## P1 — improve bot understanding

- [ ] Evaluate Graphify on UiPath XAML and project.json specifically.
- [ ] Decide whether to commit graph output or generate locally only.
- [x] Add incremental graph freshness check based on git commit/hash. Implemented in v0.11.2 as a stat-based content fingerprint (path/size/mtime) over `git ls-files --cached --others --exclude-standard`; still needs a real pilot bot workstation confirmation alongside the deterministic test coverage.
- [ ] Auto-extract an initial bot context draft from XAML/project files for human review.

## P2 — expand shared RPA standards

- [ ] Add naming rules.
- [ ] Add logging matrix.
- [ ] Add exception/retry decision table.
- [ ] Add config/asset/queue standards.
- [ ] Add REFramework variant documentation.

## P3 — evidence and governance

- [ ] Generate machine-readable evidence JSON in addition to Markdown/logs.
- [ ] Add diff-risk scoring.
- [ ] Add secret scanning before audit PASS.
- [ ] Add baseline-vs-new analyzer comparison for legacy bots with pre-existing violations.

## Later — lifecycle expansion

- [ ] Azure DevOps PR automation.
- [ ] Azure DevOps pipeline integration using the same validation policy.
- [ ] Package publish to Development Orchestrator.
- [ ] Controlled Development job/test orchestration.
- [ ] Production deployment only after explicit governance design and approval.
