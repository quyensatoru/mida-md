---
name: mida-proxy
description: Use when changing, reviewing, or adding code in the mida-proxy repository — Koa proxy routes, auth middleware, shop/proxy routing, Redis caching, RabbitMQ consumers, or upstream target configuration.
---

# MIDA Proxy Pattern

Use this skill before modifying `mida-proxy`. This is an **ESM Koa reverse proxy** that routes authenticated requests to one of N upstream API clusters based on shop domain.

## Read First

```sh
find mida-proxy/src -type f | sort
git -C mida-proxy status --short
```

## Repo Shape

```
mida-proxy/src/
├── server.js            # Entry: Koa app → static → cors → errorHandler → connectMongo → RabbitMQ → routes
├── configs/
│   ├── index.js         # Re-exports mongo & redis
│   ├── mongo.config.js  # connectMongo()
│   ├── redis.config.js  # RedisClient singleton
│   └── rabbit.config.js # RabbitMQ init
├── constants/
│   └── proxy.constant.js # API_SERVERS, HM_SERVERS, PING_SERVERS (indexed by proxy number)
├── controllers/
│   └── webhook.controller.js
├── middlewares/
│   └── auth.middleware.js  # 6 verification functions
├── models/
│   └── shop.model.js    # Shop: { domain, proxy }
├── routes/
│   ├── index.js         # combineRouters
│   ├── api.route.js     # /apiv1/* → API_SERVERS
│   ├── webhook.route.js # /webhooks/* → API_SERVERS
│   ├── event.route.js   # /sessions/* (SSE) → API_SERVERS
│   ├── hm.route.js      # /hm/* (SSE) → HM_SERVERS
│   ├── ping.route.js    # /recorder/* → PING_SERVERS
│   ├── shop.route.js    # /shops/auth → API_SERVERS
│   └── support-vahu.route.js
├── services/
│   ├── redis.service.js  # RedisService.get/set/delete
│   └── shop.service.js   # ShopService.findByDomain()
├── queues/
│   ├── index.js          # proxyRabbit() — init connection
│   ├── channel/
│   │   └── proxy.channel.js  # consume + publish
│   └── consume/
│       └── proxy.consume.js  # shop update handler
└── utils/
    ├── logger.util.js    # Logger (colored, stack trace)
    └── ip.util.js        # getClientIp()
```

**Module system:** ESM (`import`/`export`) throughout — not CommonJS.

## Purpose

Routes requests to `API_SERVERS[proxy]`, `HM_SERVERS[proxy]`, or `PING_SERVERS[proxy]` based on `shop.proxy` (1 or 2). Proxy index is resolved by auth middleware and stored in `ctx.state.proxy`.

## Auth Middleware (6 functions)

All from `src/middlewares/auth.middleware.js`. Each sets `ctx.state.proxy`:

| Function | Source of domain | Use |
|---|---|---|
| `verifyDomain` | JWT token or `?domain` query param | Most `/apiv1/*` routes |
| `verifySecretKey` | base64 `x-mida-secret-key` header | Internal service calls |
| `verifyWebhook` | `x-shopify-shop-domain` header | Shopify GDPR webhooks |
| `verifyCrmWebhook` | HMAC-SHA256 body + header | CRM webhook with signature |
| `verifyToken` | JWT `Authorization: Bearer` | Session routes |
| `verifyId` | hashids `:id` URL param | ID-based routes |

After auth, `ctx.state.proxy` = 1 or 2 (which cluster).

`verifyCrmWebhook` also sets `ctx.state.body` and `ctx.state.forwardBody`.

## Route Pattern

```js
import Router from '@koa/router';
import proxy from 'koa-proxies';
import { verifyDomain } from '../middlewares/auth.middleware.js';
import { API_SERVERS } from '../constants/proxy.constant.js';

export const apiRouter = new Router({ prefix: '/apiv1' });

apiRouter.all('/*path', verifyDomain, async (ctx, next) => {
    const index = ctx.state.proxy;  // 1 or 2

    return proxy(`/apiv1/*`, {
        target: API_SERVERS[index],
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/apiv1/, ''),
        events: {
            proxyReq: (proxyReq, req) => {
                const clientIp = getClientIp(req);
                proxyReq.setHeader('x-mida-client', clientIp);
                proxyReq.setHeader('x-forwarded-for', clientIp);
            },
            error(err) { console.log(err); },
        },
    })(ctx, next);
});
```

## SSE / WebSocket Proxy Pattern

For SSE streams, use raw `http-proxy` instead of `koa-proxies`:

```js
import httpProxy from 'http-proxy';
const sse = httpProxy.createProxyServer({ ws: true, changeOrigin: true });

heatmapRouter.get('/click', verifyDomain, async (ctx) => {
    const index = ctx.state.proxy;
    ctx.respond = false;  // bypass Koa response handling
    ctx.status = 200;
    sse.web(ctx.req, ctx.res, {
        target: HM_SERVERS[index],
        secure: false,
        headers: { ...ctx.headers },
    });
});
```

## Upstream Targets

```js
// constants/proxy.constant.js
export const API_SERVERS = { 1: process.env.API_URL_1, 2: process.env.API_URL_2 };
export const HM_SERVERS  = { 1: process.env.HM_URL_1,  2: process.env.HM_URL_2  };
export const PING_SERVERS = { 1: process.env.PING_URL_1, 2: process.env.PING_URL_2 };
```

Always use `SERVERS[index]` — never hard-code upstream URLs.

## Redis Caching

Shop-to-proxy mapping is cached with key `proxy_${domain}`:

```js
// In auth middleware
const cached = await RedisService.get(`proxy_${domain}`);
if (cached) {
    ctx.state.proxy = parseInt(cached);
} else {
    const shop = await ShopService.findByDomain(domain);
    ctx.state.proxy = shop.proxy;
    await RedisService.set(`proxy_${domain}`, shop.proxy);
}
```

## RabbitMQ Consumer

Queue `'proxy'` (durable) receives shop update messages to refresh Redis cache:

```js
// queues/consume/proxy.consume.js
const handleProxyConsume = async (channel, message) => {
    try {
        const { domain, proxy } = JSON.parse(message.content.toString());
        await RedisService.set(`proxy_${domain}`, proxy);
        channel.ack(message);
    } catch (e) {
        Logger.error(FILE, domain, e);
        channel.nack(message, false, false);
    }
};
```

## Error Handling

Global error handler in `server.js`:

```js
app.use(async (ctx, next) => {
    try {
        await next();
    } catch (err) {
        ctx.status = err.status || 500;
        ctx.body = {
            status: 'error',
            message: err.status !== 500 ? err.message : 'Internal server error',
        };
    }
});
```

Middleware throws:
```js
ctx.throw(401, 'DOMAIN IS UNDEFINED');
ctx.throw(401, 'PROXY NOT FOUND');
```

## Logger

```js
import Logger from '../utils/logger.util.js';

Logger.error(FILE, domain, error);  // Logs with stack trace
Logger.info(FILE, domain, 'message');
```

`FILE` = the current file path (`import.meta.url` or `__filename`).

## Service Patterns

```js
// services/redis.service.js
const RedisService = {
    get: async (key) => RedisClient.get(key),
    set: async (key, value, options = {}) => RedisClient.set(key, value, options),
    delete: async (key) => RedisClient.del(key),
};

// services/shop.service.js
const ShopService = {
    findByDomain: async (domain) => Shop.findOne({ domain }).lean().exec(),
};
```

## Naming Conventions

- `*.route.js` — Router definitions
- `*.middleware.js` — Auth/validation (`verify*` naming)
- `*.service.js` — Data access objects
- `*.model.js` — Mongoose schemas
- `*.util.js` — Pure utilities
- `*.config.js` — Singleton connections
- `*.channel.js` — RabbitMQ channel (IIFE)
- `*.consume.js` — Message handlers

## Strict Rules

- Do **not** use CommonJS in this repo — it is ESM throughout
- Do **not** add direct business logic to proxy routes — proxy only routes and authenticates
- Do **not** hard-code upstream URLs or proxy indices — use `*_SERVERS[index]` from constants
- Do **not** change route prefixes or existing middleware order without checking downstream effects
- Always set `ctx.respond = false` for SSE routes using raw http-proxy
- Always use `ctx.state.proxy` (not hard-coded 1 or 2) when selecting upstream

## Add Route Checklist

1. Identify which upstream target (`API_SERVERS`, `HM_SERVERS`, `PING_SERVERS`)
2. Choose correct auth middleware for the request source
3. Create `routes/*.route.js` with Router + prefix
4. Add to `routes/index.js` combineRouters
5. Test proxy with `curl` to verify headers and routing

## Verification

```sh
node --input-type=module < mida-proxy/src/routes/api.route.js  # syntax check
```
