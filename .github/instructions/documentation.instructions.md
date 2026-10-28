---
description: Use when a change needs documentation impact classification, compact AGENTS.md context, or targeted human-facing documentation routing.
---
# Documentation and Context Rules

Use documentation in proportion to the change. `Requirements/` contains canonical human-owned business requirements and evidence. `AGENTS.md` is compact reusable agent context. `.ai/context/` files are detailed, bot-owned derived topic documents. `docs/` contains human-facing project documentation. These layers have different audiences and update frequencies.

## Context loading

1. Read the root `AGENTS.md` first when it exists and is valid.
2. Inventory `Requirements/` with `Manage-RequirementsWorkspace.ps1 -Action Discover -ReadEntryPoint -Json`; the helper inventories before reading `REQUIREMENTS.md` and does not load supporting content.
3. Treat `REQUIREMENTS.md` as the structured entry point and load only supporting files relevant to the current task. Report unreadable/unsupported files only when relevant; leave them untouched.
4. Use the Change Plan and Impact Set to identify relevant `.ai/context/` and human-facing documentation topics.
5. Load multiple topics only when the change genuinely spans them; never read all requirement, context, or docs files by default.
6. For business intent, precedence is current explicit user instruction, `Requirements/`, other authoritative project documentation, implementation evidence, then inference. Current source remains authoritative for actual technical behavior.

Everything under `Requirements/` is human-owned. Do not edit, delete, rename, move, normalize, or synchronize it without explicit user instruction. Empty optional template fields are nonblocking. Surface conflicts between human artifacts without silently selecting or rewriting one. Screenshots are evidence, not selectors; examples describe possible schema/structure and are not production runtime inputs unless explicitly designated.

If no stable fact represented in `AGENTS.md` changed, set:

```text
CONTEXT_UPDATE_REQUIRED: false
```

Reuse an existing valid `AGENTS.md`; do not regenerate it for every task.

## Documentation impact

The Coordinator makes the initial classification in the Change Plan. The Developer confirms or revises it after implementation. When audit routing invokes the Auditor, the Auditor verifies the final classification from the plan, diff, and evidence.

Use exactly one level:

- `DOCUMENTATION_IMPACT: NONE` - no material change to architecture, business or user-visible behavior, interfaces, applications, file journey, configuration contract, Orchestrator resources, dependency/setup requirements, testing contract, or known limitations. No Documentation Agent, no `AGENTS.md` update, and no detailed documentation update.
- `DOCUMENTATION_IMPACT: CONTEXT_ONLY` - stable agent-relevant project facts changed, but human-facing documentation does not need a meaningful update. Update `AGENTS.md` when a key workflow, entry point, application, important dependency/resource, constraint, or persistent convention changes. Do not invoke Documentation Agent by default.
- `DOCUMENTATION_IMPACT: HUMAN_DOCS` - the documented business or technical behavior changed, including business rules, architecture, file lifecycle, inputs/outputs, operational resources, configuration schema, setup requirements, environment limitations, or significant testing procedures. Invoke Documentation Agent with targeted scope.

A small internal bug fix, selector correction, logging change, Config value change without schema change, test-only correction, or internal refactor is normally `NONE`. A new stable workflow, entry point, application, dependency, shared component, or convention is normally `CONTEXT_ONLY`. A business-rule, file-lifecycle, interface, configuration-contract, operational, or human-visible change is normally `HUMAN_DOCS`.

## Plan fields

The authoritative Change Plan should include:

```text
documentation:
  impact: NONE | CONTEXT_ONLY | HUMAN_DOCS
  reason: <evidence-based reason>
  affected_topics: []
  candidate_documents: []
```

Do not inspect every document just to fill this field. Candidate documents should be selected from the topic routing below and the Impact Set.

## Topic routing

- business rule -> `.ai/context/business-rules.md`
- application or UI -> `.ai/context/applications.md`
- file handling or lifecycle -> `.ai/context/file-journey.md`
- queue, asset, connection, or resource -> `.ai/context/orchestrator-resources.md`
- architecture or shared component -> `.ai/context/architecture.md`
- testing contract -> `.ai/context/test-catalog.md`
- environment limitation -> `.ai/context/known-issues.md`
- general human operation/process description -> `docs/Bot-Documentation.md`
- stable agent-facing project fact -> `AGENTS.md`

## Documentation Agent

Invoke RPA Documentation only when the final impact is `HUMAN_DOCS`. Send, in order:

1. the approved Change Plan;
2. the Developer documentation confirmation;
3. the changed-file list or diff and implementation evidence;
4. affected topics and candidate documents;
5. only the detailed context needed for those topics.

The Documentation Agent reads and updates only targeted documents and directly related sections. It does not rediscover the whole project or documentation corpus. It returns `DOCUMENTATION RESULT: UPDATED` or `REWORK` for `HUMAN_DOCS`.

For `NONE`, return:

```text
DOCUMENTATION_IMPACT: NONE
REASON:
<why no documented concept changed>
DOCUMENTATION_AGENT: NOT_INVOKED
CONTEXT_UPDATE_REQUIRED: false
```

For `CONTEXT_ONLY`, update `AGENTS.md` only when the stable compact context changed, then return:

```text
DOCUMENTATION_IMPACT: CONTEXT_ONLY
AGENTS_UPDATE: UPDATED | NOT_REQUIRED
DOCUMENTATION_AGENT: NOT_INVOKED
```

Do not invoke Documentation Agent merely to add one workflow or dependency to `AGENTS.md`.

## Auditor review when invoked

The Auditor verifies scope, not the entire documentation set:

- `NONE`: inspect the Change Plan, diff, and Developer confirmation; decide whether the skip is justified.
- `CONTEXT_ONLY`: verify `AGENTS.md` was updated when required and no human-facing documentation was missed.
- `HUMAN_DOCS`: verify only the candidate documents and affected sections against implementation evidence.

Do not weaken evidence, testing, UI capture, output QA, dependency, Production, approval, or PASS/REWORK/BLOCKED controls because documentation impact is low.
