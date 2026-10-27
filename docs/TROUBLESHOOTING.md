# Troubleshooting

Run diagnostics from the bot repository first:

```powershell
./.rpa-ai/scripts/Get-DevKitDiagnostics.ps1
```

The command does not print credentials or secret values. It checks the PowerShell runtime, required commands, installed manifest, UiPath project shape, Copilot customization files, managed-file hashes, and bot-local graph status.

## Outlook capability is unavailable

Run the rerunnable probe from the bot repository:

```powershell
./.rpa-ai/scripts/Test-OutlookCapability.ps1 -Json
```

It checks the project-declared UiPath Outlook/Mail package and reads the current user's default Inbox without sending, deleting, moving, or modifying mail. Read the result from `.rpa-ai/local/outlook-capability.json`. A false result can reflect the machine, user, Outlook installation, profile, or UiPath environment; it is not a permanent bot property.

When the result is false, do not keep retrying Outlook execution. Validate recipients, subject, HTML/body content and rendering, dynamic values, attachments, send conditions, and surrounding logic independently. Do not claim a send or delivery that was not tested.

## Graphify command not found

Run activation again. When Graphify, `uv`, and `pipx` are all absent, activation downloads the official portable `uv` archive, verifies its publisher SHA-256 value, installs it under `%LOCALAPPDATA%\RpaAiDevKit\tools\uv`, and then installs pinned Graphify:

```powershell
./.rpa-ai/scripts/Activate-RpaAiDevKit.ps1
```

If the download fails, verify outbound HTTPS access to `api.github.com`, `github.com`, `pypi.org`, and `files.pythonhosted.org`. Do not replace activation with a global unpinned `pip install`.

## Tool is installed in my profile but not on PATH

Run activation again. It searches common Windows user-profile locations and saves verified executable paths in `.rpa-ai/local/tool-paths.json`. The file is machine-local and ignored by Git. Do not copy another developer's cached paths.

If `uip` and npm are both absent, activation downloads the current official Node.js LTS Windows archive, verifies it against Node.js `SHASUMS256.txt`, and installs portable Node.js/npm under `%LOCALAPPDATA%\RpaAiDevKit\tools\node`. It then installs official `@uipath/cli` under `%LOCALAPPDATA%\RpaAiDevKit\tools\npm`.

If that download fails, verify outbound HTTPS access to `nodejs.org` and `registry.npmjs.org`, then rerun activation. Administrator elevation is not requested.

## Graphify version mismatch

The bot requires the version in `.rpa-ai/validation/graphify-version.json`.

```powershell
./.rpa-ai/scripts/Activate-RpaAiDevKit.ps1 -ForceGraphifyReinstall
```

Review a changed version pin through a Dev Kit payload upgrade before forcing replacement.

## Managed integrity failed

A centrally managed file is missing or differs from `.rpa-ai/kit-manifest.json`.

1. Do not edit the manifest or weaken the integrity check.
2. Review the local change.
3. Re-run `Install-RpaAiDevKit.ps1` (or re-import with `-Upgrade`); unchanged managed files are replaced automatically.
4. Use `-OverwriteManaged` only after explicitly reviewing a local conflict.
5. Put reusable Dev Kit proposals in `.ai/feedback/dev-kit-improvements.md`.

Bot-owned `preserve` files are not reset by this process.

## Dev Kit update is available

The Coordinator checks stable release tags in the canonical Azure DevOps Dev Kit repository. The check is informational. Choose **Update** only when you want to begin an upgrade; otherwise continue with the installed version.

To start an explicit update from the bot repository:

```powershell
./.rpa-ai/scripts/Update-RpaAiDevKit.ps1 -TargetBotPath . -ConfirmUpdate
```

The helper checks the current managed integrity, checks out the selected stable tag through Git, exports its payload, imports only managed files, preserves bot-owned files, activates the result, and validates integrity. If activation or validation fails, it restores the previous managed installation and reports the rollback result.

Remote version lookup failures do not block development. An explicitly requested update failure does block development until the reported rollback or local repair is complete.

## Import completed but activation failed

The importer leaves the verified payload files installed so the local prerequisite can be repaired. Fix the reported Graphify, `uv`, `pipx`, path, or permission issue, then run:

```powershell
./.rpa-ai/scripts/Activate-RpaAiDevKit.ps1
```

The Dev Kit is not ready until this command passes.

## Graph is missing or stale

```powershell
./.rpa-ai/scripts/Refresh-BotGraph.ps1 -Mode Update
```

If the command fails, treat development as blocked. Do not bypass the graph gate or invoke raw Graphify with a remote backend.

## RPA agents do not appear in Copilot Chat

1. Confirm the bot repository itself is the folder open in VS Code.
2. Confirm `.github/agents/rpa-coordinator.agent.md`, `rpa-developer.agent.md`, `rpa-documentation.agent.md`, and `rpa-auditor.agent.md` exist.
3. Open Copilot Chat customization diagnostics and inspect parse/load errors.
4. Reload the VS Code window after a fresh payload import.
5. Run Dev Kit diagnostics again.

## UiPath CLI is missing or uses another command family

Run:

```powershell
uip --help
uip rpa --help
uip skills --help
```

The bootstrap script supports current `uip rpa init` and compatible `uip rpa create-project` command families. If neither exists, install or update the approved UiPath RPA CLI/tool before continuing.

## Script execution is blocked

Use the organization-approved execution policy. For a one-time Development terminal where policy permits:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.rpa-ai\scripts\Get-DevKitDiagnostics.ps1
```

Do not weaken machine or enterprise policy without authorization.

## Browser target capture cannot run

UI authoring must stop. Verify the Development URL, approved authenticated session, UiPath UI Automation package/tooling, browser extension, and Studio/Robot capability. Report `BLOCKED_UI_CAPTURE` when a live target cannot be captured and proven; do not guess selectors.

## Build or restore fails

Read the actual `uip` output. Verify configured feeds, package access, target framework, and project pins. Do not manually invent dependency entries or silently upgrade unrelated packages.

## Output file exists but looks wrong

File creation is not completion. Inspect the generated Development artifact, fix the workflow or approved template, regenerate, and repeat schema plus readability checks. Do not manually repair only the test output.
