---
name: mida-hm
description: Use when changing, reviewing, or adding code in the mida-hm repository — Koa routes, controllers, services, ClickHouse queries, heatmap models, queue channels/consumers, schedules, or one-off jobs for heatmap and analytics processing.
---

# MIDA Heatmap (mida-hm) Pattern

Use this skill before modifying `mida-hm`. This is a **CommonJS Koa** service that processes heatmap events (clicks, scrolls, mouse movements) from Shopify stores, aggregates them into heatmaps, and provides visualization APIs.

## Read First

```sh
find mida-hm/src -maxdepth 3 -type d | sort
grep -rn "featureName\|routeName" mida-hm/src --include="*.js"
git -C mida-hm status --short
```

## Repo Shape

```
mida-hm/src/
├── server.js            # Entry: aliases → env → Koa middleware → routes → RabbitMQ → schedules
├── configs/             # app.config.js, clickhouse.config.js, db.config.js, redis.config.js
├── constants/           # enum.js (BATCH_SIZE, HEATMAP_DEVICE, EXPIRE), heatmap.js, queues.constant.js
├── controllers/         # *.controller.js — action objects
├── middleware/          # auth.middleware.js (verifyToken, verifyShopKey)
├── models/
│   ├── heatmap/         # *.heatmap.js — use connHeatmapV2 connection
│   └── gateway/         # Read-only Mongoose access to external data
├── services/
│   ├── heatmap/         # *.service.js — static method objects
│   ├── gateway/         # *.service.js — gateway queries
│   └── clickhouse/      # event.service.js — ClickHouse raw event queries
├── routes/              # *.route.js + index.js (koa-combine-routers)
├── queues/
│   ├── index.js         # RabbitHM.initRabbitMQ()
│   ├── channel/         # IIFE singleton channels
│   ├── consume/         # Message handlers
│   └── builder/         # Data transformation builders (factory functions)
├── schedules/           # *.schedule.js + index.js (node-schedule)
├── jobs/                # One-off batch jobs
├── helpers/             # mongo.helper, redis.helper, sse.helper, handle-response.helper
├── validation/          # common.validate.js
├── graphql/             # External GraphQL queries
└── logger/              # JSON structured logger
```

**Two MongoDB connections:**
- `connGatewayV2` — gateway/external data
- `connHeatmapV2` — heatmap-specific data (use this for new heatmap models)

## Route Pattern

```js
const Router = require('koa-router');
const ClickController = require('@/controllers/click.controller');
const { verifyToken } = require('@/middleware/auth.middleware');
const { validateRawData } = require('@/validation/common.validate');

const ClickRouter = new Router({ prefix: '/v2/click' });

ClickRouter.get('/', ClickController.getAll);
ClickRouter.get('/raw-data', verifyToken, validateRawData, ClickController.getRawData);
ClickRouter.put('/', verifyToken, ClickController.update);

module.exports = ClickRouter;
```

Register in `routes/index.js` with `koa-combine-routers`.

## Auth Middleware

`verifyToken` (from `@/middleware/auth.middleware`):
- Extracts `Bearer` JWT from `Authorization` header
- Verifies with `SHOPIFY_API_SECRET_KEY`, extracts domain
- Populates `ctx.state.shop` — use in controller as `ctx.state.shop`

`verifyShopKey`:
- Verifies `x-mida-shop-key` header (secret key auth)

## Controller Pattern

```js
const ClickController = {
    getAll: async (ctx) => {
        try {
            const { pageId, device, domain } = ctx.request.query;
            const shop = await ShopService.findOne({ domain });
            if (!shop) return responseHelper.error(ctx, 400, 'Shop not found');

            // SSE streaming for large datasets
            const control = createSse(ctx);
            const cursor = ClickService.findAllAndCalculate({ shopId: shop._id, pageId, device });

            await cursor.eachAsync(async (batch) => {
                control.emit({ id: batch?.[0]?._id, data: { data: batch } });
            }, { batchSize: BATCH_SIZE.POINT });

        } catch (e) {
            error(__filename, 'APP', `click error: ${e.message}`);
        } finally {
            control.close();
        }
    },
};

module.exports = ClickController;
```

**Response helpers** (from `@/helpers/handle-response.helper`):
```js
responseHelper.success(ctx, 200, data, 'OK');
responseHelper.error(ctx, 400, 'error message');
```

**Logger** (from `@/logger`):
```js
const { debug, error, info, warn } = require('@/logger');
error(__filename, domain, e);         // domain = shop domain string
debug(__filename, domain, 'message');
```

## Service Pattern

```js
const ClickService = {
    findById: (id) => ClickHM.findById(id),
    deleteMany: async (filter) => await ClickHM.deleteMany(filter),

    // Bulk upsert using bulkWrite for efficiency
    bulkUpsertV2: async (points) => {
        const operations = points.map((point) => ({
            updateOne: {
                filter: { pageview: point.pageview, x: point.x, y: point.y },
                update: { $inc: { counts: point.counts }, $setOnInsert: { ...point } },
                upsert: true,
            },
        }));
        if (operations.length) await ClickHM.bulkWrite(operations, { ordered: false });
    },

    // Cursor for streaming large datasets
    findAllAndCalculate: ({ shopId, pageId, device, batchSize = BATCH_SIZE.POINT }) => {
        const pipeline = [ /* aggregation */ ];
        return PageViewHM.aggregate(pipeline).cursor({ batchSize });
    },
};

module.exports = ClickService;
```

**Service method naming:**
- `find()` → returns query
- `findOne()` → single doc
- `findCount()` → aggregation count
- `upsert()` → create or update
- `bulkUpsert()` / `bulkWrite()` → batch operations
- `aggregate()` → pipeline

**Always use `bulkWrite()` for batch updates** — never loop individual `updateOne()` calls.

## Mongoose Aggregate Helper

```js
const { Aggregate } = require('@/helpers/mongo.helper');

const pipeline = [
    Aggregate.match(filter),
    Aggregate.lookup({ from: 'pageviews', localField: 'pageview', foreignField: '_id', as: 'pv' }),
    Aggregate.unwind('$pv'),
    Aggregate.group({ _id: '$shop', total: { $sum: 1 } }),
    Aggregate.project({ _id: 0, shop: '$_id', total: 1 }),
];
```

## Model Pattern

```js
// models/heatmap/click.heatmap.js
const { connHeatmapV2 } = require('@/configs/db.config');

const ClickSchema = new Schema({
    x: { type: Number, default: 0 },
    y: { type: Number, default: 0 },
    counts: { type: Number, default: 0 },
    pageview: { type: Schema.Types.ObjectId, ref: 'PageView' },
    type: { type: String },
    query: { type: String },
}, { versionKey: false });

ClickSchema.index({ pageview: 1, x: 1, y: 1 });

module.exports = connHeatmapV2.model('ClickV2', ClickSchema);
```

- Always use `connHeatmapV2` for heatmap models
- `versionKey: false` always
- Define indexes on frequently queried fields

## ClickHouse Pattern

```js
// services/clickhouse/event.service.js
const clickHouse = require('@/configs/clickhouse.config');

const EventClickHouse = {
    findHM: async ({ sessionId, pageviewId, time }) => {
        const query = `
            SELECT hmType, data, timestamp
            FROM events
            WHERE sessionId = '${sessionId}'
              AND pageView = '${pageviewId}'
              AND hmType IN (1,2,3)
              ${time ? `AND timestamp > ${time}` : ''}
        `;
        return await clickHouse.query({ query, format: 'JSONEachRow' });
    },
};
```

ClickHouse is read-only supplementary source. Always specify `format: 'JSONEachRow'`.

## Queue Channel Pattern

```js
const PointChannel = (function () {
    let channel;

    const initial = async (conn) => {
        channel = await conn.createChannel();
        await channel.assertExchange('point_v2', 'direct', { durable: true });
        channel.prefetch(200);
        for (const name of ['click', 'move', 'scroll', 'conversion']) {
            await channel.assertQueue(name, { durable: true });
            channel.bindQueue(name, 'point_v2', name);
            channel.consume(name, (msg) => handleSavePoints(channel, msg));
        }
    };

    const publish = async (queue, message) => {
        const buf = Buffer.from(JSON.stringify(message));
        await channel.sendToQueue(queue, buf, { persistent: true });
    };

    return { initial, publish };
})();
```

**Consumer with ack/nack:**
```js
const handleSavePoints = async (channel, message) => {
    let id = null;
    try {
        if (message === null) return;
        const { type, pageview, points } = JSON.parse(message.content.toString());
        id = pageview?.pageview;
        // process by type...
        channel.ack(message);
    } catch (e) {
        channel.nack(message, false, false);
        error(__filename, `ID: ${id}`, e);
    }
};
```

## Validation Middleware

```js
// validation/common.validate.js
const validateRawData = async (ctx, next) => {
    const { device, startDate, endDate } = ctx.request.query;
    if (!startDate || !endDate) return responseHelper.error(ctx, 400, 'startDate and endDate required');
    if (!Object.values(HEATMAP_DEVICE).includes(device)) return responseHelper.error(ctx, 400, 'device is invalid');
    await next();
};
```

## Schedule Pattern

```js
// schedules/index.js
const ScheduleHM = {
    initial: async () => {
        schedule.scheduleJob('*/30 * * * *', HeatmapSchedule.buildShop);
        schedule.scheduleJob('0 2 * * *', HeatmapSchedule.clearOutDate);
        schedule.scheduleJob('0 * * * *', HeatmapSchedule.clearHMSession);
    },
};
```

## Batch Processing Constants

```js
const BATCH_SIZE = { POINT: 250, PAGEVIEW: 100, EVENT: 400 };
```

Always use constants for batch sizes — never hard-code.

## Strict Rules

- Do **not** introduce Express, TypeScript, or ESM
- Do **not** use individual `updateOne()` loops — use `bulkWrite()`
- Do **not** load unbounded collections into memory — use cursors with `batchSize`
- Do **not** pass `ctx` to services
- Always close SSE connections in `finally` block
- Always use `connHeatmapV2` for heatmap models (not the default connection)
- Always use constants for queue names, batch sizes, device types

## Verification

```sh
node -c mida-hm/src/controllers/click.controller.js
pnpm exec eslint mida-hm/src/controllers/click.controller.js
```
