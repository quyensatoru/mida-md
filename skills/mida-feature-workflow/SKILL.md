---
name: mida-feature-workflow
description: Use when building a new feature from a Jira ticket — orchestrates Jira MCP → Figma MCP → Shopify Dev MCP → repo skill into a single implementation workflow.
---

# MIDA Feature Development Workflow

Use this skill when given a Jira ticket (e.g. `MAH-123`) to implement. It sequences all available MCPs and repo skills to go from task → working code.

## When to invoke

- User provides a Jira issue key (`MAH-xxx`, `MIDA-xxx`, etc.)
- User says "implement [feature]" and references a ticket
- Starting a new feature branch from a Jira task

## Step-by-step Workflow

### Step 1 — Read Jira Task

Use the `jira-mcp` to fetch the full issue:

```
get issue: <ISSUE_KEY>
```

Extract:
- **Title + description** — the feature intent
- **Acceptance criteria** — what "done" looks like
- **Labels / components** — which repo(s) are affected (e.g. `mida-cms`, `mida-api`)
- **Figma link** — usually in description or attachments (look for `figma.com/file/...` or `figma.com/design/...`)
- **Linked issues** — upstream/downstream dependencies to be aware of

If the ticket has subtasks, read each one too.

### Step 2 — Read Figma Design (if link found)

Use the `figma-developer-mcp` with the URL from Step 1:

```
get_figma_data: { fileKey, nodeId? }
```

Extract from the design:
- **Frame structure** — top-level layout (which page/component)
- **Component tree** — names of each UI node and their hierarchy
- **Auto layout direction + gap** — maps to `<BlockStack>` / `<InlineStack>` + gap token
- **Spacing / padding values** — convert to Polaris space tokens
- **Color / tone** — map to Polaris `tone` props (critical, warning, success, info)
- **Text styles** — map to `<Text variant="...">` values
- **Interactive elements** — buttons, inputs, selects, toggles

If there are multiple frames (desktop / mobile / states), read the primary one first.

### Step 3 — Validate Polaris Components (if feature touches mida-cms UI)

Use the `shopify-dev-mcp` to confirm correct component usage:

```
search_docs_chunks: "component name + usage context"
validate_component_codeblocks: <generated JSX snippet>
```

Use this to:
- Confirm the right Polaris component for each Figma element (use the mapping table in `mida-skills:mida-cms`)
- Validate props are correct for Polaris 12
- Check if the target surface is App Home or Admin UI extension (affects available components)

### Step 4 — Load the Relevant Repo Skill

Based on which repo(s) the Jira ticket affects, invoke the matching skill **before writing any code**:

| Affected area | Skill to invoke |
|---|---|
| Frontend UI / pages / components | `mida-skills:mida-cms` |
| API routes / services / models | `mida-skills:mida-api` |
| Heatmap / ClickHouse | `mida-skills:mida-hm` |
| Session recording | `mida-skills:mida-recorder` |
| Search / Elasticsearch | `mida-skills:mida-search` |
| MCP tools / AI assistant | `mida-skills:mida-mcp` |
| Shopify extension (liquid) | `mida-skills:mida-extension` |
| Proxy / auth routing | `mida-skills:mida-proxy` |

Most features touch both `mida-cms` (frontend) and `mida-api` (backend) — load both skills.

### Step 5 — Synthesize and Implement

Combine all gathered context:

1. **Requirements** from Jira (what to build + acceptance criteria)
2. **UI spec** from Figma (layout, components, spacing)
3. **Polaris validation** from Shopify Dev MCP (correct component + props)
4. **Repo patterns** from the skill (file structure, naming, patterns to follow)

Then implement following the checklist in the relevant skill (e.g. `mida-skills:mida-cms` Add Feature Checklist).

## Output per Step

| Step | What to tell the user |
|---|---|
| After Step 1 | Summary: task title, affected repos, Figma link found/not found |
| After Step 2 | UI spec: list of Polaris components to build, spacing summary |
| After Step 3 | Validation result: any component corrections needed |
| After Step 4 | Confirm patterns loaded, ready to implement |
| After Step 5 | List files created/modified, how to test |

## When Figma Link is Missing

If no Figma link in the Jira ticket:
1. Ask the user: "Do you have a Figma link for this task?"
2. If yes → go to Step 2
3. If no → skip Steps 2–3, implement based on Jira description + existing UI patterns in the codebase

## When Jira MCP is Not Connected

If `jira-mcp` returns an error or is not configured:
1. Ask the user to describe the feature requirements
2. If they provide a Figma link → go to Step 2
3. Proceed with available context

## Strict Rules

- Always read the Jira ticket **before** writing any code — requirements drive implementation
- Always load the repo skill **before** writing any code for that repo
- If Figma exists, always map to Polaris — do not invent custom UI outside Polaris
- Acceptance criteria from Jira = the definition of done; verify each criterion is met before declaring complete
