# MIDA Agent Skills

Skills for all coding agents working in this workspace. Each skill covers one repo's architecture, patterns, naming conventions, and strict rules.

**How to use:** Before modifying any repo, read the corresponding skill file to understand conventions and avoid regressions.

## Skills Index

| Skill file | Repo | Tech stack | Use when |
|---|---|---|---|
| [mida-api.md](./mida-api.md) | `mida-api` | CommonJS / Koa / Mongoose / RabbitMQ (5 connections) | Main backend: routes, controllers, services, models, queues, jobs, automation |
| [mida-cms.md](./mida-cms.md) | `mida-cms` | React / Redux / Polaris / Vite / Turborepo | Frontend admin app: components, pages, hooks, services, state management |
| [mida-hm.md](./mida-hm.md) | `mida-hm` | CommonJS / Koa / ClickHouse / Mongoose | Heatmap service: click/scroll/move aggregation, SSE streaming, queue consumers |
| [mida-proxy.md](./mida-proxy.md) | `mida-proxy` | ESM / Koa / http-proxy / Redis | Reverse proxy: routing, auth middleware, upstream cluster selection |
| [mida-recorder.md](./mida-recorder.md) | `mida-recorder` | CommonJS / Koa / Mongoose / GeoIP | Session recorder: ping tracking, middleware chain, quota, VIP queue routing |
| [mida-search.md](./mida-search.md) | `mida-search` | CommonJS / Express / Elasticsearch / Mongoose | Search indexing: ES queries, queue consumers (backup_mongo_db), aggregations |
| [mida-mcp.md](./mida-mcp.md) | `mida-mcp` | ESM / Express / MCP SDK / Redis | AI tools server: MCP tool definitions, multi-shard models, cache-aside |
| [code-extension.md](./code-extension.md) | `code-extension` | Vanilla JS / Webpack / rrweb / Liquid | Shopify extension: recorder/survey/GDPR modules, theme liquid injection |

## Quick Reference

### Module systems
- **CommonJS** (`require`/`module.exports`): `mida-api`, `mida-hm`, `mida-recorder`, `mida-search`
- **ESM** (`import`/`export`): `mida-proxy`, `mida-mcp`, `code-extension`
- **React/JSX**: `mida-cms`

### Auth patterns
- `mida-api` — `verifySessionToken`, `verifySecretKey` (9 middleware functions)
- `mida-hm` — `verifyToken` → `ctx.state.shop`
- `mida-proxy` — `verifyDomain` → `ctx.state.proxy` (cluster index)
- `mida-recorder` — 9-step middleware chain → `ctx.state.shopData` + `ctx.state.midaApp`
- `mida-mcp` — JWT → proxy lookup → quota check → `req.contextShop`

### Response helpers
- `mida-api` — `clientSuccess(ctx, code, payload, msg)` / `clientError(ctx, code, msg)`
- `mida-hm` — `responseHelper.success(ctx, code, data)` / `responseHelper.error(ctx, code, msg)`
- `mida-search` — `res.json({ success, payload, statusCode })`
- `mida-mcp` — `{ content: [{ type: 'text', text: formattedOutput }] }`

### Queue patterns
- All services use IIFE singleton channels with `initialize(conn)` / `publish(queue, msg)`
- All consumers: `channel.ack(message)` on success, `channel.nack(message, false, false)` on failure
- Never requeue failed messages (2nd + 3rd args to nack are always `false`)

### Logger
All backends use the same logger pattern:
```js
logger.error(__filename, domain, errorOrMessage);
logger.debug(__filename, domain, 'message');
```
