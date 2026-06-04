---
name: mida-recorder
description: Use when changing, reviewing, or adding code in the mida-recorder repository — Koa routes, controllers, services, Mongoose models, middleware chain, queue channels/consumers, geolocation, compression, or automation jobs for session recording and behavior tracking.
---

# MIDA Recorder Pattern

Use this skill before modifying `mida-recorder`. This is a **CommonJS Koa** service that receives session tracking pings, validates quota/consent/IP rules, and routes data through RabbitMQ for downstream processing.

## Read First

```sh
find mida-recorder -maxdepth 3 -type f -name "*.js" | grep -v node_modules | sort
git -C mida-recorder status --short
```

## Repo Shape

```
mida-recorder/
├── server.js                  # Entry: env → RabbitMQ → MongoDB → GeoIP → Koa middleware → listen → automation
├── routes/
│   ├── index.js               # Route aggregator
│   └── session.route.js       # POST /sessions/* with 9-step middleware chain
├── controllers/
│   ├── Ping.Controller.js     # Main ping handler (PascalCase.controller.js)
│   ├── Session.controller.js
│   ├── Shop.controller.js
│   └── ...
├── services/
│   ├── session.service.js     # Session CRUD (exports.findOne, exports.upsert, ...)
│   ├── shop.service.js        # Shop queries + quota aggregations
│   ├── setting.service.js
│   ├── redis.service.js       # Redis wrapper
│   └── ...
├── models/
│   ├── session.model.js       # Session + indexes
│   ├── sessionMissing.model.js
│   ├── shop.model.js
│   ├── setting.model.js       # excluded_ips, excluded_countries, require_consent
│   ├── module.model.js        # Feature flags: key enum ['sr', 'sv']
│   └── visitor-block.model.js
├── middleware/
│   └── auth.middleware.js     # 9 verify* functions
├── queues/
│   ├── init.queue.js          # Two AMQP connections (API + recorder)
│   ├── channel/
│   │   ├── session.channel.js      # Publish to domain-keyed queues (VIP sharding)
│   │   ├── backup.channel.js       # Consume from API (shop_v2, session_v2, ...)
│   │   └── missingSession.channel.js
│   └── consume/
│       ├── backup-v2.consume.js    # Handle shop/session/setting updates
│       └── missingSession.consume.js
├── helpers/
│   ├── session.helper.js      # Session type/source detection
│   ├── rabbit.helper.js       # VIP queue routing
│   ├── geodb.helper.js        # IP → location
│   ├── userAgent.helper.js    # UA parsing
│   ├── genRedisKey.helper.js  # Redis key generators
│   └── ipAddress.helper.js    # CIDR range checking
├── config/                    # DB, Redis, RabbitMQ configs
├── constants/
│   ├── cache.constant.js      # Redis key patterns + expiration times
│   └── plan.constant.js       # VIP plan list
├── logger/                    # JSON structured logger
├── automation/                # Automation class + cron jobs
└── jobs/                      # Manual CLI jobs
```

## Server Initialization Order

1. `RabbitConfig.init()` — both AMQP connections
2. `DBConfig.connect()` — MongoDB
3. `openIp2Location()` — GeoIP database
4. Koa: `koaUA` → `errorHandler` → `cors` → `koaBody` → `appRouter`
5. `automation.run()` — scheduled jobs

## Two AMQP Connections

```js
// API RabbitMQ → used for publishing session events
AMQP_API_URI = process.env.AMQP_API_URI

// Recorder RabbitMQ → used for consuming backup messages from mida-api
AMQP_RECORDER_URI = process.env.AMQP_RECORDER_URI
```

## Request Middleware Chain (9 steps)

All ping endpoints go through this chain — each step populates `ctx.state`:

```js
sessionRouter.post('/tracker',
    verifyParams,           // validate domain, page_key, session_key, page_href
    verifyIp,               // extract IP → ctx.state.midaApp.ip
    verifyShop,             // load Shop → ctx.state.shopData
    verifyBlackList,        // check visitor-block model
    verifyModule(['sr']),   // check SR module enabled (3 min cache)
    verifyQuota,            // check session_count vs quota limit
    verifySetting,          // load setting → check IP/country exclusions
    verifyUserAgent,        // parse browser/OS/device → ctx.state.midaApp
    (ctx) => tracker(ctx)   // controller
);
```

**ctx.state conventions:**
- `ctx.state.shopData` = `{ _id, domain, plan_code, shopify_plan, session_count, ... }`
- `ctx.state.midaApp` = `{ ip, location, address, os, browser, device, quota, ... }`

## Controller Pattern

```js
// controllers/Ping.Controller.js (PascalCase file naming)
async function ping(ctx) {
    let res = { statusCode: 200, message: 'OK', block: false };
    try {
        const { ip, location, os, browser } = ctx.state.midaApp;
        const { _id: shopId, domain, shopify_plan } = ctx.state.shopData;
        const { session_key, page_key } = ctx.request.query;

        // Check Redis cache first
        const blockCached = await RedisService.get(`block:${session_key}`);
        if (blockCached) {
            ctx.body = { statusCode: 403, message: 'This ping is blocked', block: true };
            return;
        }

        // Business logic
        await rabbitHelper.publishSessionEvent({ shopify_plan, sessionKey: session_key, data: { ... } });

    } catch (e) {
        logger.error(__filename, ctx.state.shopData?.domain, e);
        res = { statusCode: 500, message: e.message };
    } finally {
        ctx.body = res;  // Always set ctx.body in finally
    }
}
```

## Service Pattern

```js
// services/session.service.js — exports.foo style
exports.findOne = function (filter, projection = {}) {
    return Session.findOne(filter, projection).exec();
};

exports.findById = function (id, shopId, projection = {}) {
    return Session.findOne({ _id: id, shop: shopId }, projection).lean().exec();
};

exports.upsert = function (update) {
    return Session.findOneAndUpdate(
        { _id: update._id },
        update,
        { upsert: true, new: true }
    );
};

exports.countMonthly = ({ shopId, from, to }) => {
    return Session.countDocuments({
        shop: shopId,
        createdAt: { $gte: from, $lte: to },
    });
};
```

Always filter by `shop._id` for multi-tenant isolation.

## Key Models

**Session model** (`session.model.js`):
- `key`, `shop`, `visitor`, `os`, `device`, `browser`, `location`, `ip`
- `source: { url, type }` (enum: organic/direct/referred/paid)
- `type` (enum: successful-order/abandoned-checkout/abandoned-cart)
- `customer_id`, `customer_email`, `cart_value`, `tags`
- Index: `{ shop: 1, key: 1 }`

**Module model** (`module.model.js`):
- `key: enum['sr', 'sv']` — sr = session recording, sv = session visitor
- `status: Boolean` — feature enabled for shop

**Setting model** (`setting.model.js`):
- `excluded_ips`, `excluded_countries`
- `require_consent`, `collect_email`
- `replay_speed`, `replay_autoplay`

## Queue Channel Pattern (IIFE)

```js
// queues/channel/session.channel.js
const SessionChannel = (function () {
    let channel;

    const initialize = async (conn) => {
        channel = await conn.createChannel();
        await channel.assertQueue('session', { durable: true });
        channel.prefetch(1, false);
    };

    const publish = async (queue, message) => {
        const buf = Buffer.from(JSON.stringify(message));
        channel.publish('domain', queue, buf, { persistent: false });
    };

    return { initialize, publish };
})();

module.exports = SessionChannel;
```

## VIP Queue Routing

VIP plans distribute across multiple queues (10 or 15) for throughput:

```js
// helpers/rabbit.helper.js
if (SHOPIFY_PLAN.VIP_PLAN.includes(shopify_plan)) {
    const index = PingBuilder.getQueueIndex(sessionKey, 10);  // hash mod 10
    await SessionChannel.publish(`${domain}_${index}`, data);
} else {
    await SessionChannel.publish(domain, data);
}
```

## Queue Consume Pattern

```js
const BackupConsume = {
    shop_v2: async (channel, message) => {
        let domain = null;
        try {
            const { event, data } = JSON.parse(message.content.toString());
            domain = data.domain;
            switch (event) {
                case 'save':
                    await ShopService.upsert(data);
                    break;
                case 'updateOne':
                    await ShopService.updateOne({ _id: data._id }, data);
                    break;
            }
            channel.ack(message);
        } catch (e) {
            logger.error(__filename, domain, e.toString());
            channel.nack(message, false, false);  // reject, no requeue
        }
    },
};
```

## Redis Caching Pattern

```js
const { genSettingKey } = require('@/helpers/genRedisKey.helper');
const { REDIS_EXPIRATION_TIME } = require('@/constants/cache.constant');

// Cache-aside pattern
const cacheKey = genSettingKey(shopId);
let setting = await RedisService.get(cacheKey);

if (setting) {
    setting = JSON.parse(setting);
} else {
    setting = await SettingService.getSettingsByShop({ shopId });
    await RedisService.set(cacheKey, JSON.stringify(setting), { EX: REDIS_EXPIRATION_TIME });
}
```

## Event Compression

DOM snapshots and mutations are gzip-compressed before queueing:

```js
// queues/builder/ping.builder.js
if ((event.type === 3 && event.data.source === 0) || event.type === 2) {
    const buffer = await gzipAsync(JSON.stringify(event.data));
    processedEvents.push({ ...event, data: { compressed: buffer.toString('base64') } });
}
```

## Error Handling

Sentry-integrated error handler — known business errors are filtered:

```js
// These errors are expected and NOT sent to Sentry:
// 'Quota limit!', 'Bot was blocked', 'Excluded countries',
// 'Skip preview mode', 'Invalid module'
```

Throw pattern:
```js
if (!domain) ctx.throw(400, 'Invalid domain');
if (!shop) ctx.throw(404, 'Shop not found');
if (blocked) ctx.throw(403, 'Visitor is blocked!');
```

## Logger

```js
const logger = require('./logger');
logger.error(__filename, domain, error);   // domain = shop domain string
logger.debug(__filename, domain, 'message');
logger.info(__filename, domain, 'message');
```

## Automation (Cron)

```js
// automation/index.js
const job = new Automation(
    'job-name',
    '0 0 * * *',          // Midnight daily
    async () => {
        try { /* work */ }
        catch (e) { logger.error(__filename, '', e); }
    }
);
```

## Naming Conventions

- Controllers: `PascalCase.controller.js`
- Services: `camelCase.service.js`
- Models: `camelCase.model.js`
- Routes: `camelCase.route.js`
- Helpers: `camelCase.helper.js`
- Channels: `camelCase.channel.js`
- Consumers: `camelCase.consume.js`

## Strict Rules

- Do **not** introduce TypeScript, ESM, or new frameworks
- Do **not** skip the middleware chain for new ping/tracker endpoints
- Always filter all DB queries by `shop._id` (multi-tenant)
- Always use `exports.foo` style for services (not `module.exports = {}`)
- Always set `ctx.body` in a `finally` block for ping endpoints
- Use `REDIS_EXPIRATION_TIME` constants — never hard-code TTL values
- VIP plans must use `rabbitHelper.publishSessionEvent()` — never publish directly to domain queue

## Verification

```sh
node -c mida-recorder/server.js
node -c mida-recorder/controllers/Ping.Controller.js
```
