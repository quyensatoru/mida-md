# MIDA Skills

Coding skills for all MIDA workspace repos. Covers architecture patterns, naming conventions, and strict rules for 8 repos.

---

## Installation

### Claude Code

**Bước 1 — Add marketplace (1 lần duy nhất):**
```sh
claude plugin marketplace add quyensatoru/mida-md
```

**Bước 2 — Install plugin:**
```sh
claude plugin install mida-skills
```

**Bước 3 — Enable trong project** (`.claude/settings.json`):
```json
{
  "enabledPlugins": {
    "mida-skills": true
  }
}
```

Sau khi install, skills xuất hiện dưới dạng:
- `mida-skills:mida-api`
- `mida-skills:mida-cms`
- `mida-skills:mida-hm`
- `mida-skills:mida-proxy`
- `mida-skills:mida-recorder`
- `mida-skills:mida-search`
- `mida-skills:mida-mcp`
- `mida-skills:code-extension`

**Update plugin khi có skill mới:**
```sh
claude plugin update mida-skills
```

**Local dev (không cần marketplace):**
```sh
claude plugin install /path/to/mida/.agents
```

---

### Codex (OpenAI)

**Option 1 — Copy to project `.codex/skills/`:**
```sh
# From workspace root
cp -r .agents/skills/* .codex/skills/
```

**Option 2 — Symlink:**
```sh
mkdir -p .codex/skills
for skill in .agents/skills/*/; do
  ln -sf "$(pwd)/$skill" ".codex/skills/$(basename $skill)"
done
```

**Option 3 — Use `.codex-plugin/`** (if Codex supports plugin install):
```sh
codex plugin install /path/to/mida/.agents
```

---

### Gemini CLI

```sh
# Copy gemini-extension.json and GEMINI.md to project root
cp .agents/gemini-extension.json ./
cp .agents/GEMINI.md ./
```

Or if Gemini CLI supports plugin install, point it at this directory.

---

### Cursor / Other AI editors

Copy the relevant `skills/<repo>/SKILL.md` content into the editor's custom instructions or rules file for that project.

---

## Skills Index

| Skill | Repo | Stack | Use when |
|---|---|---|---|
| `mida-api` | `mida-api/` | CommonJS / Koa / Mongoose / RabbitMQ | Main backend: routes, controllers, services, models, queues, jobs |
| `mida-cms` | `mida-cms/` | React / Redux / Polaris / Vite | Frontend admin app: components, pages, hooks, services |
| `mida-hm` | `mida-hm/` | CommonJS / Koa / ClickHouse | Heatmap: click/scroll/move aggregation, SSE streaming |
| `mida-proxy` | `mida-proxy/` | ESM / Koa / http-proxy | Reverse proxy: routing, auth, cluster selection |
| `mida-recorder` | `mida-recorder/` | CommonJS / Koa / Mongoose / GeoIP | Session recorder: ping, quota, VIP queue sharding |
| `mida-search` | `mida-search/` | CommonJS / Express / Elasticsearch | Search indexing: ES queries, queue consumers |
| `mida-mcp` | `mida-mcp/` | ESM / Express / MCP SDK | AI tools server: tool definitions, multi-shard models |
| `code-extension` | `code-extension/` | Vanilla JS / Webpack / Liquid | Shopify extension: recorder/survey modules, web pixel |

---

## Plugin Structure

```
.agents/
├── .claude-plugin/
│   ├── plugin.json          # Claude Code manifest
│   └── marketplace.json     # Claude marketplace listing
├── .codex-plugin/
│   └── plugin.json          # Codex manifest
├── gemini-extension.json    # Gemini CLI extension
├── CLAUDE.md                # Claude Code context
├── GEMINI.md                # Gemini CLI context
├── package.json             # npm package
├── README.md                # This file
└── skills/
    ├── mida-api/SKILL.md
    ├── mida-cms/SKILL.md
    ├── mida-hm/SKILL.md
    ├── mida-proxy/SKILL.md
    ├── mida-recorder/SKILL.md
    ├── mida-search/SKILL.md
    ├── mida-mcp/SKILL.md
    └── code-extension/SKILL.md
```

---

## Quick Reference

### Module systems
- **CommonJS** (`require`/`module.exports`): `mida-api`, `mida-hm`, `mida-recorder`, `mida-search`
- **ESM** (`import`/`export`): `mida-proxy`, `mida-mcp`, `code-extension`
- **React/JSX**: `mida-cms`

### Auth patterns
| Repo | Pattern |
|---|---|
| mida-api | `verifySessionToken` + 8 others → `ctx.state.shopState` |
| mida-hm | `verifyToken` → `ctx.state.shop` |
| mida-proxy | `verifyDomain` → `ctx.state.proxy` (cluster 1 or 2) |
| mida-recorder | 9-step chain → `ctx.state.shopData` + `ctx.state.midaApp` |
| mida-mcp | JWT → proxy → quota → `req.contextShop` |

### Queue rules (all repos)
- Channel: IIFE singleton with `initialize(conn)` / `publish(queue, msg)`
- Consumer: `channel.ack(msg)` on success, `channel.nack(msg, false, false)` on failure
- **Never** requeue — 3rd arg to nack is always `false`

### Logger (all backend repos)
```js
logger.error(__filename, domain, errorOrMessage);
logger.debug(__filename, domain, 'message');
```

---

## Updating Skills

When repo patterns change, update the corresponding `skills/<name>/SKILL.md` and the flat `*.md` copy:

```sh
# Edit skill
vim .agents/skills/mida-api/SKILL.md
# Sync to flat copy (for tools that read from .agents root)
cp .agents/skills/mida-api/SKILL.md .agents/mida-api.md
```
