---
name: mida-search
description: Use when changing, reviewing, or adding code in the mida-search repository — Express routes, controllers, services, Elasticsearch index mappings/queries, queue consumers (backup_mongo_db), or batch migration jobs for search indexing.
---

# MIDA Search Pattern

Use this skill before modifying `mida-search`. This is a **CommonJS Express** service that indexes MongoDB data into Elasticsearch and provides search/analytics APIs.

## Read First

```sh
find mida-search/src -type f | sort
git -C mida-search status --short
```

## Repo Shape

```
mida-search/src/
├── index.js               # Entry: aliases → env → Express → listen → ES init → MongoDB → RabbitMQ
├── config/
│   ├── elastic.config.js  # ES client (ELK_URI, ELK_USER, ELK_PASSWORD)
│   └── mongoose.config.js # MongoDB connection
├── constant/
│   ├── session.js         # Event types, source types, session types
│   └── visitor.js         # Visitor constants
├── controllers/
│   ├── session.controller.js  # Object of async functions
│   └── visitor.controller.js
├── helpers/
│   ├── elastic.helper.js      # ElasticQuery builder (term, range, terms, bool, etc.)
│   ├── session.helper.js      # Session filter → ES query builder
│   ├── visitor.helper.js
│   └── common.helper.js       # Shared filter builders
├── jobs/
│   ├── index.js               # Job runner
│   └── copy-db.js             # MongoDB → Elasticsearch migration
├── logger/                    # JSON structured logger (LOGGER=1 env var)
├── models/                    # Mongoose schemas (read source for queue consumers)
│   ├── session.model.js
│   ├── visitor.model.js
│   ├── pageview.model.js
│   └── page.model.js
├── queues/
│   ├── index.js               # initRabbitMQ() + auto-reconnect
│   ├── channels/
│   │   └── backup.channel.js  # 4 queues: backup_session, backup_visitor, backup_pageview, backup_page
│   └── consumes/
│       └── backup.consume.js  # event switch: save/update/deleteOne/deleteMany
├── routes/
│   ├── index.js               # Express router aggregator
│   ├── session.route.js       # POST /session/*
│   └── visitor.route.js       # POST /visitor/*
└── services/
    ├── elastic.service.js     # Low-level ES API wrapper
    ├── elk.service.js         # Index initialization (initIndexes)
    ├── session.service.js     # Session CRUD + query + aggregations
    ├── visitor.service.js
    ├── pageview.service.js
    └── page.service.js
```

**Bootstrap sequence:**
1. `ElasticService.initIndexes()` — create 4 ES indexes if not exist
2. `mongoose.connect()` — MongoDB
3. `initRabbitMQ()` — start consumers

## Route Pattern

```js
// All endpoints are POST (payload in body)
const router = express.Router();
router.post('/', SessionController.findAll);
router.post('/metrics', SessionController.metrics);
router.post('/top_referring_domains', SessionController.topReferringDomains);
module.exports = router;
```

No auth middleware — internal service called by mida-api only.

## Controller Pattern

```js
const SessionController = {
    findAll: async (req, res) => {
        try {
            const { shopId, visitorFilters, sessionFilters, _limit = 10, _skip = 0 } = req.body;

            const result = await SessionService.query({
                shopId, filter: sessionFilters, limit: _limit, skip: _skip,
            });

            res.status(200).json({
                success: true,
                payload: {
                    currentPage: Math.floor(_skip / _limit) + 1,
                    totalPage: Math.ceil(result.total / _limit),
                    sessions: result.items,
                },
                statusCode: 200,
            });
        } catch (e) {
            res.status(500).json({ success: false, message: e.message, statusCode: 500 });
        }
    },
};
```

**Response format always:** `{ success, payload, statusCode }`.

## Service Pattern

```js
const SessionService = {
    // CRUD
    insert: async (data) => ElasticService.insertDocument('session', data._id, data),
    updateDocument: async (id, update, doc) => ElasticService.updateDocument('session', id, update, doc),
    deleteDocById: async (id) => ElasticService.deleteDocument('session', id),
    deleteDocByQuery: async (query) => ElasticService.deleteDocumentByQuery('session', query),
    bulkInsert: async (data) => ElasticService.bulkInsert('session', data),

    // Query with pagination
    query: async ({ shopId, filter, limit = 10, skip = 0, sort }) => {
        const query = SessionHelper.buildQuery(filter, shopId);
        const result = await ElasticService.search('session', { query, size: limit, from: skip, sort });
        return {
            total: result.hits.total.value,
            items: result.hits.hits.map(h => ({ _id: h._id, ...h._source })),
        };
    },

    // Aggregations
    metrics: async ({ shopId, filter }) => {
        // size: 0 + date_histogram + terms aggregations
    },
};
```

## ElasticQuery Helper (use for all query building)

```js
const ElasticQuery = require('../helpers/elastic.helper');

// Build queries compositionally
ElasticQuery.term('shop', shopId)           // { term: { shop: shopId } }
ElasticQuery.terms('events', ['add-to-cart', 'checkout'])
ElasticQuery.range('createdAt', { gte: from, lte: to })
ElasticQuery.bool({ must: [...], must_not: [...] })
ElasticQuery.exists('orders')
ElasticQuery.regexp('address.city', 'Hanoi.*')
```

## Elasticsearch Patterns

**Index mapping conventions:**
- `keyword` — exact match fields (shop, visitor, device, browser, location, events)
- `date` — time fields (createdAt, last_active)
- `float`/`integer` — numeric metrics (duration, active_duration)
- `object` — nested objects (source, address, cart_value)
- Text with `.keyword` sub-field: `{ type: "text", fields: { keyword: { type: "keyword" } } }`

**Aggregation-only query (no documents):**
```js
{
    size: 0,
    _source: false,
    query: { bool: { must: [{ term: { shop: shopId } }, { range: { createdAt: { gte, lte } } }] } },
    aggs: {
        orders_by_source: {
            filter: { bool: { must: [{ terms: { "source.type": ["organic", "paid"] } }] } },
            aggs: { by_source: { terms: { field: "source.type.keyword" } } },
        },
    },
}
```

**Bulk indexing:**
```js
const body = documents.flatMap(doc => {
    const { _id, ...rest } = doc;
    return [{ index: { _index: indexName, _id } }, rest];
});
await elasticClient.bulk({ body });
```

**Multi-tenant:** Always filter by `{ term: { shop: shopId } }`.

## Queue Consumer Pattern

**Channel setup** (`backup.channel.js`):
- Direct exchange `backup_mongo_db`
- 4 queues: `backup_session`, `backup_visitor`, `backup_pageview`, `backup_page`
- `prefetch(300)` for rate limiting
- Durable queues and messages

**Consumer** (`backup.consume.js`):
```js
const BackupConsume = {
    backup_session: async (channel, message) => {
        try {
            const { event, data } = JSON.parse(message.content.toString());
            switch (event) {
                case 'save':
                    if (data) await SessionService.insert(data);
                    break;
                case 'update':
                    const { _conditions, _update, _doc } = data;
                    if (_conditions?._id) await SessionService.updateDocument(_conditions._id, _update, _doc);
                    break;
                case 'deleteOne':
                case 'deleteMany':
                    if (data?._id && typeof data._id === 'string') {
                        await SessionService.deleteDocById(data._id);
                    } else {
                        const query = SessionHelper.buildQueryDelete(data);
                        if (query) await SessionService.deleteDocByQuery(query);
                    }
                    break;
            }
            channel.ack(message);
        } catch (e) {
            logger.error(__filename, 'backup_session', e);
            channel.nack(message, false, false);  // reject, no requeue
        }
    },
};
```

## Auto-Reconnect Pattern

```js
const initRabbitMQ = async () => {
    connection = await amqp.connect(AMQP_URI);
    BackupChannel.initial(connection);
    connection.on('error', () => reconnectRabbitMQ());
    connection.on('close', () => reconnectRabbitMQ());
};

const reconnectRabbitMQ = () => setTimeout(initRabbitMQ, 10000);
```

## Logger

```js
const { debug, error, info, warn } = require('./logger');
error(__filename, 'APP', `Error inserting session: ${e.message}`);
// JSON format: { filename, caller, level, domain, message, time }
```

## Pagination

```js
// Consistent across all query endpoints
const totalPages = Math.ceil(total / limit);
const currentPage = Math.floor(skip / limit) + 1;
```

## Strict Rules

- Do **not** introduce Koa, TypeScript, or ESM — this is CommonJS Express
- All endpoints are **POST** — no GET for query endpoints
- Always include `{ term: { shop: shopId } }` in every ES query
- Use `ElasticQuery.*` helpers — never build raw query objects inline
- `channel.nack(message, false, false)` — never requeue failed messages
- `size: 0` for aggregation-only queries — never fetch documents unnecessarily
- Always call `ElkService.initIndexes()` on startup — indexes may not exist in dev

## Verification

```sh
node -c mida-search/src/services/session.service.js
node -c mida-search/src/controllers/session.controller.js
```
