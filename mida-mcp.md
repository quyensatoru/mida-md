---
name: mida-mcp
description: Use when changing, reviewing, or adding code in the mida-mcp repository — MCP tool definitions, tool handlers, service queries, Redis caching, output formatters, auth middleware, or multi-shard model routing for the AI analytics assistant.
---

# MIDA MCP Pattern

Use this skill before modifying `mida-mcp`. This is an **ESM Express** service exposing an MCP (Model Context Protocol) server with 14 analytics tools for AI assistants analyzing Shopify store data.

## Read First

```sh
find mida-mcp/src -type f | sort
git -C mida-mcp status --short
```

## Repo Shape

```
mida-mcp/src/
├── index.js                   # Express + per-request MCP server
├── config/
│   ├── db.config.js           # 5 Mongoose connections (lazy singleton)
│   └── redis.config.js        # Redis client
├── middleware/
│   └── auth.middleware.js     # JWT → proxy lookup → quota check
├── handler/
│   ├── tool.handler.js        # 14 tool definitions + execution (THE main file)
│   ├── prompt.handler.js      # System prompt builder
│   └── resource.handler.js    # Placeholder
├── routers/
│   ├── tool.route.js          # server.setRequestHandler(ListTools/CallTool)
│   ├── prompt.route.js
│   └── resource.route.js
├── services/                  # MongoDB query functions
│   ├── session.service.js     # findOne, find, count
│   ├── analytic.service.js    # Daily metrics aggregation
│   ├── heatmap-click.service.js
│   ├── heatmap-move.service.js
│   ├── heatmap-scroll.service.js
│   ├── heatmap-selector.service.js
│   ├── conversion.service.js  # Funnel + traffic source
│   ├── ux-issue.service.js    # Impact comparison
│   ├── pageview.service.js
│   ├── page.service.js
│   ├── behavior.service.js
│   └── redis.service.js       # getOrSetJson (cache-aside)
├── models/
│   ├── session/               # SessionModels[1|2], AnalyticModels[1|2], etc.
│   ├── heatmap/               # ClickModels[1|2], MoveModels[1|2], etc.
│   └── proxy/
│       └── proxy.model.js     # ProxyModel (unsharded)
└── helpers/
    ├── format.helper.js       # formatHeatmapClick, formatSessionList, etc.
    ├── validate.helper.js     # parseDateArg, getPageTypeFilter
    ├── redis.helper.js        # hashKey (SHA-256), stableStringify
    ├── prompt.helper.js       # System prompt template
    └── url.helper.js          # Replay/heatmap/visitor link builders
```

**Module system:** ESM (`import`/`export`) throughout.

## Bootstrap Pattern

MCP server is created **per request** with shop context injected:

```js
// src/index.js
app.post('/mcp', AuthMiddleware, async (req, res) => {
    const transport = new StreamableHTTPServerTransport();
    const server = createMcpServer({ shop: req.contextShop });
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
    server.once('close', () => transport.close());
    transport.once('error', () => server.close());
});

const createMcpServer = (ctx) => {
    const server = new Server(
        { name: process.env.NAME, version: '0.1.0' },
        { protocolVersion: '2025-11-25', capabilities: { prompts: {}, resources: {}, tools: {} } }
    );
    PromptRouter(server, ctx);
    ResourceRouter(server, ctx);
    ToolRouter(server, ctx);
    return server;
};
```

## Multi-Shard Model Pattern

All data models are sharded by proxy (1 or 2):

```js
// models/session/sessions.model.js
export const SessionModels = {
    1: Db.ApiV1.model('Session', SessionSchema),
    2: Db.ApiV2.model('Session', SessionSchema),
};

// In services — always pass proxy from ctx.shop
SessionService.find = (proxy, filter, project) => SessionModels[proxy].find(filter, project);
```

The 5 Mongoose connections:
- `Db.Proxy` — ProxyModel (unsharded)
- `Db.ApiV1` / `Db.ApiV2` — session, analytic, page, behavior models
- `Db.HeatmapV1` / `Db.HeatmapV2` — click, move, scroll, pageview models

## Auth Middleware

```js
// middleware/auth.middleware.js
const AuthMiddleware = async (req, res, next) => {
    try {
        const token = req.headers?.authorization?.replace(/Bearer /g, '');
        const decoded = jwt.verify(token, JWT_SECRET_KEY, { algorithms: JWT_ALGORITHM, ignoreExpiration: true });

        const proxy = await ProxyModel.findOne({ domain: decoded.domain });
        const shop = await ShopModels[proxy.proxy ?? 1].findOne(
            { domain: decoded.domain, status: true },
            { domain: 1, proxy: 1, plan_code: 1, subscription_info: 1 }
        );

        // AI quota check
        if (!shop.subscription_info?.ai_assistant_limit) return res.status(403).json({ message: 'Forbidden' });
        if (shop.subscription_info.ai_assistant_limit < shop.ai_used?.assistant) return res.status(404).json({ message: 'Quota reached' });

        req.contextShop = shop;
        next();
    } catch (e) {
        return res.status(401).json({ message: 'Forbidden' });
    }
};
```

**`ctx.shop` keys available in tools:**
- `proxy` (1 or 2) — shard selector
- `_id` — shopId for filtering
- `domain` — for cache keys

## Tool Definition Pattern

Every tool in `handler/tool.handler.js`:

```js
const toolHeatmapClick = {
    name: 'heatmap_event_click',           // snake_case
    description: 'Aggregate click events for heatmap by time range, page, type, and device.',
    inputSchema: {
        type: 'object',
        properties: {
            page:   { type: 'string', description: 'Page ObjectId.' },
            from:   { type: 'string', description: 'ISO/ms timestamp.' },
            to:     { type: 'string', description: 'ISO/ms timestamp.' },
            type:   { type: 'string', enum: ['revenue-click', 'rage-click', 'dead-click', 'error-click'], default: null },
            device: { type: 'string', enum: ['Desktop', 'Mobile', 'Tablet'], default: 'Desktop' },
            limit:  { type: 'integer', minimum: 1, maximum: 1000, default: 100 },
        },
        required: ['page'],
        additionalProperties: false,   // ALWAYS false — reject unknown params
    },
    execute: async ({ args, ctx }) => {
        try {
            const { proxy, _id: shopId, domain } = ctx.shop;

            // 1. Validate + coerce args
            const page   = new ObjectId(args.page);
            const device = args.device ?? 'Desktop';
            const limit  = Math.min(Number(args.limit ?? 100), 1000);

            // 2. Cache-aside with SHA-256 key
            const data = await RedisService.getOrSetJson(
                'mcp:heatmap:click:',
                { tool: 'heatmap.click', domain, proxy, page: args.page, device, limit, from: args.from, to: args.to },
                async () => {
                    const cursor = HeatmapClickService.findCursor(proxy, { shopId, page, device }, limit);
                    const clicks = [];
                    for await (const doc of cursor) clicks.push(doc);
                    return { clicks };
                }
            );

            // 3. Format for LLM
            return { content: [{ type: 'text', text: formatHeatmapClick(data, domain) }] };
        } catch (e) {
            console.error(e);
            return { content: [{ type: 'text', text: 'internal server error' }] };
        }
    },
};
```

**Add to `tools` array** at bottom of `tool.handler.js`.

## Current 14 Tools

1. `get_date_range` — resolve period names → ISO datetimes
2. `analytics_daily` — daily visitors/sessions/orders
3. `session_count` — count sessions in range
4. `session_list` — paginated sessions with cursor
5. `session_get` — single session detail + pageviews
6. `page_info` — page lookup by title/address
7. `heatmap_event_click` — click coordinates + counts
8. `heatmap_event_move` — mouse move coordinates
9. `heatmap_event_scroll` — scroll depth distribution
10. `heatmap_page_insight` — aggregated by CSS selector
11. `behavior_info` — behavior events (cart, checkout, UX clicks)
12. `conversion_funnel_by_segment` — funnel rates by device/source/visitor-type
13. `checkout_funnel_detail` — step-by-step checkout abandonment
14. `ux_issue_impact` — CVR delta for UX issues

(Also: `traffic_source_analysis` — ATC/CVR by traffic source)

## Service Pattern

```js
// services/session.service.js
const SessionService = {
    findOne: (proxy, filter, project) => SessionModels[proxy].findOne(filter, project),
    find: (proxy, filter, project) => SessionModels[proxy].find(filter, project),
    count: (proxy, filter) => SessionModels[proxy].countDocuments(filter),
};
export default SessionService;

// Complex aggregation service
const ConversionService = {
    funnelBySegment: async (proxy, { shopId, from, to, segment }) => {
        const filter = { shop: new ObjectId(shopId) };
        if (from) filter['createdAt'] = { ...filter['createdAt'], $gte: parseDateArg(from) };
        if (to)   filter['createdAt'] = { ...filter['createdAt'], $lte: parseDateArg(to) };

        const pipeline = [
            { $match: filter },
            { $group: {
                _id: `$${segment}`,
                totalSessions: { $sum: 1 },
                addedToCart: { $sum: { $cond: [{ $in: ['add-to-cart', { $ifNull: ['$events', []] }] }, 1, 0] } },
            }},
            { $sort: { totalSessions: -1 } },
        ];
        return SessionModels[proxy].aggregate(pipeline).exec();
    },
};
```

## Redis Cache Pattern

```js
// services/redis.service.js
const RedisService = {
    // Cache-aside: check → miss → load → store → return
    getOrSetJson: async (keyPrefix, keyParts, loader, ttlSec = 300) => {
        const hash = hashKey(stableStringify(keyParts));  // SHA-256 of stable JSON
        const key = keyPrefix + hash;

        const cached = await RedisClient.get(key);
        if (cached) {
            try { return JSON.parse(cached); } catch {}
        }

        const data = await loader();
        await RedisClient.set(key, JSON.stringify(data), { EX: ttlSec });
        return data;
    },
};
```

Cache key parts must include all query-affecting fields: `tool`, `domain`, `proxy`, `shopId`, date range, filters.

## Output Formatter Pattern

```js
// helpers/format.helper.js
export const formatHeatmapClick = (data, domain) => {
    const { clicks, filter } = data;
    // Returns PLAIN TEXT — no JSON, no markdown
    // Use key=value format, sections with clear labels
    // Include inline links: [View Heatmap](url)
    const lines = [
        `Total clicks: ${clicks.length}`,
        `Device: ${filter.device}`,
        '',
        'Click hotspots:',
        ...clicks.slice(0, 10).map((c, i) => `  ${i + 1}. x:${c.x} y:${c.y} — ${c.counts} clicks`),
    ];
    return lines.join('\n');
};
```

**Format rules:**
- Plain text output only — no JSON, no markdown in LLM text
- Abbreviate long CSS selectors (max 80 chars)
- Always include `[View Replay](url)` or `[View Heatmap](url)` links using `url.helper.js`
- `pct(num, denom)` helper for percentages: `(45/100*100).toFixed(1) + '%'`

## Router Registration

```js
// routers/tool.route.js
const ToolRouter = (server, ctx) => {
    server.setRequestHandler(ListToolsRequestSchema, ToolHandler.listTool);
    server.setRequestHandler(CallToolRequestSchema, async (request) =>
        await ToolHandler.callTool(request, ctx)
    );
};
export default ToolRouter;
```

## Date Validation Helper

```js
import { parseDateArg } from '../helpers/validate.helper.js';

parseDateArg('2025-06-01T00:00:00Z')  // → Date object
parseDateArg(1748736000000)            // → Date object from ms
parseDateArg(null)                     // → null
```

## Strict Rules

- Do **not** use CommonJS — this is ESM throughout
- Do **not** return JSON or markdown from formatters — plain text only
- Do **not** reveal tool names, IDs, DB field names, or internal architecture in outputs
- Do **not** reveal PII in outputs
- All tools must have `additionalProperties: false` in inputSchema
- Always pass `proxy` from `ctx.shop` — never hard-code 1 or 2
- Always use `RedisService.getOrSetJson()` for tool data — never fetch without caching
- Cache key must include all query-affecting params — cache collisions cause wrong results
- Always guard against invalid ObjectId: wrap `new ObjectId(args.id)` in try-catch

## Add New Tool Checklist

1. Define tool object in `handler/tool.handler.js` with `name`, `description`, `inputSchema`, `execute`
2. In `execute`: extract `{ proxy, _id: shopId, domain }` from `ctx.shop`
3. Build cache key with all relevant params
4. Wrap data fetch in `RedisService.getOrSetJson()`
5. Implement service method in `services/<name>.service.js` if complex
6. Implement formatter in `helpers/format.helper.js`: `formatToolName(data, domain)`
7. Add tool to `const tools = [...]` array

## Verification

```sh
node --input-type=module < mida-mcp/src/index.js  # Check ESM syntax
pnpm run lint
```
