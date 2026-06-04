---
name: mida-api
description: Use when changing, reviewing, or adding code in the mida-api repository — Koa routes, controllers, services, Mongoose models, helpers, constants, middleware, queues, automation jobs, Shopify/external integrations, analytics, search insight, or error insight flows.
---

# MIDA API Pattern

Use this skill before modifying `mida-api`. The API is a **CommonJS Node/Koa** service with Mongoose, RabbitMQ (5 connections), Redis, ClickHouse, Shopify GraphQL/Admin APIs, cron automation, and one-off jobs.

## Read First

Start from the nearest existing implementation:

```sh
find mida-api -maxdepth 4 -type d | grep -v node_modules | sort
grep -rn "featureName\|routeName\|serviceName" mida-api --include="*.js"
git -C mida-api status --short
```

Open the route, controller, service, model, helper, and constant files in the same domain before editing.

## Repo Shape

```
mida-api/
├── server.js            # Entry: dotenv → alias → Sentry → MongoDB → GeoDB → Currency → RabbitMQ → middleware → routes
├── automation/          # Cron jobs (Automation class + cron expression)
├── configs/             # DB, Redis, RabbitMQ config files
├── constants/           # *.constant.js, *.const.js
├── controllers/         # internal/ external/ shopify/  — own Koa ctx
├── graphql/             # Shopify GraphQL queries
├── helpers/             # Shared logic (error.helper, mongodb.helper, graphql, etc.)
├── jobs/                # One-off migrations (npm run job <name>)
├── middleware/          # auth.middleware.js (9 functions)
├── models/              # session/ shop/ analytic/ clickhouse/ ...
├── queues/
│   ├── channel/         # Singleton IIFE channels (publish, initialize/init)
│   └── consume/         # Message handlers (parse, ack, nack)
├── routes/
│   ├── index.js         # combineRouters — MUST manually add new routers here
│   ├── internal/
│   ├── external/
│   └── shopify/
├── services/            # Business logic — no ctx
│   ├── internal/
│   ├── external/
│   ├── shopify/
│   ├── clickhouse/
│   └── redis.service.js
└── validation/          # *.validation.js — request shape checks
```

**Server initialization order:**
1. `require('module-alias/register')` — enables `@/` alias
2. `require('dotenv').config()`
3. `Sentry.init()`
4. `database.connect()` — MongoDB
5. `initGeoDatabase()`, `CurrencyHelper.initCurrencyRate()`
6. `RabbitConfig.init()` — initializes all 5 AMQP connections
7. Koa middleware stack → routes

**Module system:** CommonJS only — `require`, `module.exports`, `exports.foo`. No ESM, no TypeScript.

**Path aliases:** `@/` maps to repo root via `jsconfig.json` + `module-alias`.

## RabbitMQ Architecture

Five separate AMQP connections — pick the right one for new channels:

| Connection | Env var | Used for |
|---|---|---|
| default | `AMQP_URI` | email, survey, analytic, webhook, session |
| external | `AMQP_EXTERNAL_URI` | CDN |
| recorder | `AMQP_RECORDER_URI` | recording backup |
| heatmap | `AMQP_HEATMAP_URI` | heatmap, revenue-click |
| search | `AMQP_SEARCH_URI` | search backup |

## Layer Rules

- **Route** — HTTP method/path/prefix + middleware order
- **Middleware** — auth, plan, IP, date checks; populates `ctx.state`
- **Controller** — parse `ctx`, call services, build response; never pass `ctx` to services
- **Service** — query Mongo/Redis/ClickHouse, call Shopify/external, publish queues
- **Model** — schema, indexes, hooks; no business logic in hooks unless required
- **Helper** — reused pure-ish logic; not for single-use feature code
- **Constant** — stable enum/labels/limits; never hard-code queue names or plan codes

## Route Pattern

```js
const Router = require('@koa/router');
const Controller = require('@/controllers/internal/config/integration.controller');
const { verifySessionToken } = require('@/middleware/auth.middleware');
const Validation = require('@/validation/internal/config/integration.validation');

const integrationRouter = new Router({ prefix: '/integration' });

integrationRouter.post('/connection/:appName',
    verifySessionToken,       // auth first
    Validation.connection,    // request shape
    Controller.upsertConnection
);

module.exports = integrationRouter;
```

**Add to `routes/index.js`** — no auto-discovery. Import and add to `combineRouters(...)`.

## Auth Middleware (9 functions)

All from `@/middleware/auth.middleware.js`:

| Function | Use |
|---|---|
| `verifySessionToken` | JWT Bearer from Shopify — most internal routes |
| `verifyShopToken` | JWT for shop auth endpoints |
| `verifySecretKey` | base64 `x-mida-secret-key` header |
| `verifyShop` | domain-based shop lookup |
| `verifyModule(key)` | HOF: returns middleware checking feature module status |
| `verifyIp` | detects client IP |
| `verifySetting` | checks excluded IPs/countries from shop settings |
| `verifyUserAgent` | parses browser/OS/device |
| `verifyExportToken` | JWT for export endpoints |
| `detectIp` | gets IP without throwing |

`verifySessionToken` populates `ctx.state.shopState`. `verifySecretKey` populates `ctx.state.shopSetting`.

## Logger Pattern

```js
const logger = require('@/logger');

logger.debug(__filename, domain, 'message');
logger.info(__filename, domain, 'message');
logger.warn(__filename, domain, 'message');
logger.error(__filename, domain, 'message or Error object');
logger.success(__filename, domain, 'message');
```

`domain` = shop domain string (e.g. `'shop.myshopify.com'`). Always pass `__filename` as first arg.

## Controller Pattern

Three response styles — match the file's local style, do not normalize:

**Style 1 — clientSuccess/clientError (newer):**
```js
const { clientSuccess, clientError } = require('@/helpers/error.helper');

async function getData(ctx) {
    const { shopState } = ctx.state;
    try {
        const result = await SomeService.find({ shopId: shopState._id });
        return clientSuccess(ctx, 200, result, 'OK');
    } catch (e) {
        logger.error(__filename, shopState.domain, e);
        return clientError(ctx, 500, 'Internal server error');
    }
}
module.exports = { getData };
```

**Style 2 — direct ctx.body (legacy):**
```js
ctx.status = 200;
ctx.body = { statusCode: 200, message: 'OK', payload: result };
```

**Style 3 — analytics endpoints:**
```js
ctx.status = 200;
ctx.body = { data: result };
```

**SSE pattern:**
```js
const { createSse } = require('@/helpers/sse.helper');
const control = createSse(ctx);
control.emit({ id: sectionName, data: payload });
control.close();
```

## Service Pattern

```js
// exports.foo style (preferred)
exports.findByShop = async ({ shopId, startDate, endDate }) => {
    return SomeModel.find({ shop: shopId, createdAt: { $gte: startDate, $lte: endDate } })
        .lean().exec();
};

// Or object export (match local file)
module.exports = {
    findByShop: async ({ shopId }) => { ... },
};
```

**Redis service:**
```js
const RedisService = require('@/services/redis.service');

await RedisService.set(key, value, { EX: 3600 });
const value = await RedisService.get(key);
await RedisService.delete(key);
await RedisService.incr(key);
```

## Queue Channel Pattern

**Standard channel (Pattern A):**
```js
const SomeChannel = (function () {
    let channel;

    const initialize = async (conn) => {
        channel = await conn.createChannel();
        await channel.assertExchange('exchange_name', 'direct', { durable: true });
        await channel.assertQueue('queue_name', { durable: true });
        channel.prefetch(5);
    };

    const publish = async (queue, message) => {
        const buf = Buffer.from(JSON.stringify(message));
        channel.publish('exchange_name', queue, buf, { persistent: true });
    };

    return { initialize, publish };
})();

module.exports = SomeChannel;
```

**Sharded channel (Pattern B — used for analytic.channel to keep per-shop order):**
- `init` (not `initialize`) with separate publish and consume channels
- `hashToUint32(shopId) % SHARD_COUNT` to select queue index

**Queue consume pattern:**
```js
const handleConsume = async (channel, message) => {
    try {
        if (message === null) {
            logger.debug(__filename, '', 'drop_channel');
            return;
        }
        const { event, data } = JSON.parse(message.content.toString());
        // process...
        channel.ack(message);
    } catch (e) {
        logger.error(__filename, '', e);
        channel.nack(message, false, false); // reject, no requeue
    }
};
```

## Mongoose Model Rules

- Use `.lean().exec()` for read-only results
- Use `convertObjectId` or `new Types.ObjectId(...)` consistently with local file
- Preserve indexes and enum constants

**Model hooks (pre/post) trigger downstream sync:**
- `Session`, `Shop`, `PageView` hooks publish to heatmap/recorder/search channels
- `pre` hook = query before operation; `post` hook = receives result after
- Never bypass hooks with raw collection writes unless requirement explicitly accepts that

**ClickHouse fallback:**
```js
if (process.env.USE_CLICKHOUSE !== 'true') {
    // MongoDB fallback path
}
```

## Automation (Cron)

```js
// automation/<domain>/<name>.auto.js
module.exports = async function runJob() {
    try {
        // work
        logger.success(__filename, '', 'done');
    } catch (e) {
        logger.error(__filename, '', e);
        Sentry.captureException(e);
    }
};

// Register in automation/index.js:
new Automation('job-name', '0 */6 * * *', require('./<domain>/<name>.auto'));
```

## Jobs (One-off)

```sh
npm run job <job-name>   # e.g. npm run job migrate-pricing-plan
```

Add a `case` in `jobs/index.js`. Jobs get Mongo/Rabbit from the dispatcher — no duplicate setup.

## Naming

- `*.route.js` / `*.controller.js` / `*.service.js` / `*.model.js`
- `*.helper.js` / `*.constant.js` or `*.const.js` / `*.validation.js`
- `*.channel.js` / `*.consume.js` / `*.auto.js` / `*.job.js`

## Strict Rules

- Do **not** introduce Express, NestJS, TypeScript, ESM, or new frameworks
- Do **not** change route names, response keys, SSE event names, or queue names unless explicitly asked
- Do **not** normalize old response shapes or refactor unrelated style
- Do **not** bypass Mongoose hooks for Session, Shop, or PageView without checking heatmap/recorder/search downstream effects
- Do **not** hard-code queue names, plan codes, segment values — use constants
- Do **not** run destructive jobs or broad deletes without scoped filters and explicit approval
- Do **not** edit `.env` files unless asked
- Do **not** move logic to helpers until 2+ callers need it

## Add Feature Checklist

1. Find nearest existing feature path — copy its layering
2. Add/update constants first
3. Add validation middleware only for request-shape checks
4. Add service (no `ctx`)
5. Add controller (preserves response contract)
6. Add/update route + register in `routes/index.js`
7. Add queue/automation only if async work is required
8. Search stale references: `grep -rn "oldName\|newName" mida-api`

## Verification

```sh
node -c path/to/changed.file.js
pnpm exec eslint path/to/changed.file.js
```

Report any skipped verification for queues, cron, Shopify calls, Redis, MongoDB, or ClickHouse.
