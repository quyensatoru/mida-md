# MIDA Skills Plugin

This plugin provides coding skills for the MIDA workspace. Each skill covers one repo's architecture, patterns, naming conventions, and strict rules.

## Available Skills

| Skill | Trigger repo | Use when |
|---|---|---|
| `mida-skills:mida-api` | `mida-api/` | Modifying routes, controllers, services, models, queues, jobs, or automation in the main Koa/Mongoose backend |
| `mida-skills:mida-cms` | `mida-cms/` | Modifying React/Redux frontend pages, components, hooks, services, or Polaris UI |
| `mida-skills:mida-hm` | `mida-hm/` | Modifying heatmap service: ClickHouse queries, aggregations, SSE streaming, queue consumers |
| `mida-skills:mida-proxy` | `mida-proxy/` | Modifying proxy routing, auth middleware, upstream configuration, or Redis shop cache |
| `mida-skills:mida-recorder` | `mida-recorder/` | Modifying session recording ping/tracker: middleware chain, quota, VIP queue routing |
| `mida-skills:mida-search` | `mida-search/` | Modifying Elasticsearch indexing, query services, or backup queue consumers |
| `mida-skills:mida-mcp` | `mida-mcp/` | Adding or modifying MCP tools, services, Redis cache, or output formatters |
| `mida-skills:mida-extension` | `mida-extension/` | Modifying Shopify extension modules, liquid blocks, webpack config, or web pixel |

## Quick Reference

### Module systems
- **CommonJS** (`require`/`module.exports`): `mida-api`, `mida-hm`, `mida-recorder`, `mida-search`
- **ESM** (`import`/`export`): `mida-proxy`, `mida-mcp`, `mida-extension`
- **React/JSX**: `mida-cms`

### Auth patterns by repo
- `mida-api` — `verifySessionToken` + 8 other middleware functions
- `mida-hm` — `verifyToken` → `ctx.state.shop`
- `mida-proxy` — `verifyDomain` → `ctx.state.proxy` (cluster 1 or 2)
- `mida-recorder` — 9-step middleware chain → `ctx.state.shopData` + `ctx.state.midaApp`
- `mida-mcp` — JWT → proxy lookup → quota check → `req.contextShop`

### Queue pattern (all repos)
- Channel: IIFE singleton with `initialize(conn)` / `publish(queue, msg)`
- Consumer: `channel.ack(message)` on success, `channel.nack(message, false, false)` on failure
- Never requeue failed messages

### Logger (all backend repos)
```js
logger.error(__filename, domain, errorOrMessage);
logger.debug(__filename, domain, 'message');
```
