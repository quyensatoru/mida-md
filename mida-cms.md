---
name: mida-cms
description: Use when changing, reviewing, or adding code in the mida-cms repository — React/Redux frontend pages, components, hooks, services, API calls, Polaris UI, state management, Shopify auth flow, or shared packages (replayer, mcp).
---

# MIDA CMS Pattern

Use this skill before modifying `mida-cms`. This is a **Shopify admin app** built as a Turborepo monorepo: a React SPA frontend + Node/Express backend + shared packages.

## Read First

```sh
ls mida-cms/web/frontend/
ls mida-cms/packages/
grep -rn "featureName\|componentName" mida-cms/web/frontend --include="*.jsx" --include="*.js"
```

## Monorepo Shape

```
mida-cms/
├── web/
│   ├── index.js              # Express server entry (Shopify OAuth)
│   ├── auth/
│   │   └── afterAuth.js      # Post-OAuth: generate JWT, call backend /shops/auth
│   └── frontend/             # React SPA (Vite)
│       ├── App.jsx            # Root: providers + file-based routing
│       ├── index.jsx          # createRoot entry
│       ├── pages/             # Route-level pages (auto-discovered via Vite glob)
│       ├── components/        # Reusable UI (Common/, Dashboard/, Analytics/, etc.)
│       ├── hooks/             # Custom React hooks
│       ├── services/          # API service layer
│       │   ├── api/           # *.service.js per domain
│       │   └── index.js       # Barrel: export * as featureApi
│       ├── redux/             # State management
│       │   ├── reducers/      # Redux Toolkit slices
│       │   ├── actions/       # Action creators
│       │   └── sagas/         # Redux-Saga side effects
│       ├── helpers/           # *.helper.js (pure functions)
│       ├── hooks/             # useFeatureName.js
│       ├── consts/            # *.const.js
│       └── config/
│           ├── repository.config.js   # HTTP client factory
│           └── index.js               # Shopify app config
├── packages/
│   ├── @mida/mcp/            # MCP integration (TypeScript + Vite + TailwindCSS + Shadcn)
│   └── @mida/replayer/       # RRWeb session replay UI (Svelte + Rollup)
└── extensions/               # Shopify app extensions
```

## Tech Stack

- **React 18** + **React Router v6**
- **Vite 4** (bundler + dev server)
- **Redux Toolkit** + **Redux-Saga** (state + side effects)
- **@shopify/polaris 12** (UI components)
- **Polaris Viz** (charts)
- **SWR 2** (data fetching/caching)
- **React Hook Form** + **Yup** (forms)
- **i18next** (internationalization)
- **Shopify App Bridge 3** (iframe/session)

## File Naming

- Components: `ComponentName.jsx` (PascalCase) or `ComponentName/index.jsx`
- Services: `entity.service.js` (camelCase)
- Hooks: `useHookName.js` (`use` prefix)
- Helpers: `feature.helper.js`
- Reducers: `feature.reducer.js`, Sagas: `feature.saga.js`
- Constants: `Feature.const.js` (PascalCase)
- CSS modules: `ComponentName.module.css` or `style.module.css`

## Import Patterns

**Path alias** `@/` → `web/frontend/` root (configured in `vite.config.js`):

```js
import { selectShop } from '@/redux/reducers/general.reducer';
import LoadingModal from '@/components/Common/LoadingModal';
import { sessionApi } from '@/services';
```

**Barrel exports** for services:
```js
// services/index.js
export * as sessionApi from './api/session.service.js';

// Usage:
import { sessionApi, analyticApi } from '@/services';
await sessionApi.deleteSession({ ids, jwt });
```

## Component Pattern

```jsx
// components/FeatureName/index.jsx
import { BlockStack, Card } from '@shopify/polaris';
import styles from './style.module.css';
import clsx from 'clsx';

export default function FeatureName({ prop1, onAction }) {
    const [state, setState] = useState(null);

    const handleAction = useCallback(() => {
        // ...
    }, []);

    return (
        <Card>
            <BlockStack gap="400">
                <div className={clsx(styles.container, state && styles.active)}>
                    {/* content */}
                </div>
            </BlockStack>
        </Card>
    );
}
```

- Default export for pages and components
- Destructure props in function signature
- Use Polaris components for all UI — no custom layout primitives
- CSS Modules for scoped styles; `clsx` for conditional classes

## API Service Pattern

```js
// services/api/feature.service.js
import { repositoryApi } from '@/config/repository.config';

export async function getFeatureData({ shopId, jwt }) {
    const res = await repositoryApi.get(`/feature/${shopId}`, {
        headers: { Authorization: `Bearer ${jwt}` }
    });
    const json = await res.json();
    return { ok: json?.statusCode === 200, data: json?.payload };
}

export async function updateFeature({ id, data, jwt }) {
    const res = await repositoryApi.put(`/feature/${id}`, data, {
        headers: { Authorization: `Bearer ${jwt}` }
    });
    const json = await res.json();
    return { ok: json?.statusCode === 200 };
}
```

- Always include `Authorization: Bearer ${jwt}` for authenticated endpoints
- `repositoryApi` = main API; `repositoryRecorder` = recorder; `repositoryHeatmap` = heatmap
- Return `{ ok, data, message }` — never throw from service functions
- Export to `services/index.js` barrel

## Streaming API (SSE)

```js
import { fetchEventSource } from '@microsoft/fetch-event-source';

export const streamFeatureData = ({ params, signal, onEvent }) => {
    return fetchEventSource(`${SERVER_URL}/feature/stream?${params}`, {
        method: 'GET',
        headers: { Accept: 'text/event-stream', Authorization: `Bearer ${jwt}` },
        onmessage(event) {
            if (event.data) onEvent(event.event || 'message', JSON.parse(event.data));
        },
        signal,
    });
};
```

## Redux Pattern

**Slice (reducer + actions):**
```js
// redux/reducers/feature.reducer.js
const featureSlice = createSlice({
    name: 'feature',
    initialState: { data: null, loading: false, error: null },
    reducers: {
        setData: (state, action) => { state.data = action.payload; },
        setLoading: (state, action) => { state.loading = action.payload; },
    },
});

export const { setData, setLoading } = featureSlice.actions;
export const selectFeature = (state) => state.feature;
export default featureSlice;
```

**Saga:**
```js
// redux/sagas/feature.saga.js
function* fetchFeatureData(action) {
    try {
        const jwt = action.payload;
        const res = yield call(featureApi.getFeatureData, { jwt });
        yield put(setData(res.data));
    } catch (e) {
        yield put(setError(e.message));
    }
}

export default function* featureSaga() {
    yield takeLatest(FETCH_FEATURE, fetchFeatureData);
}
```

Register in `redux/sagas/index.js` rootSaga with `yield all([..., featureSaga()])`.

## SWR Hook Pattern

```js
// hooks/useFeatureSWR.js
import useSWR from 'swr';

export function useFeatureSWR({ shopId, startDate, endDate }) {
    const key = shopId ? `/feature/${shopId}?start=${startDate}&end=${endDate}` : null;
    const { data, error, isLoading } = useSWR(key, fetchData, { shouldRetryOnError: false });
    return { data: data?.payload, error, isLoading };
}
```

## Shopify Auth Pattern

JWT token is generated in `web/auth/afterAuth.js` after Shopify OAuth and attached to all API calls:

```js
// In afterAuth.js (server-side)
const token = jwt.sign({ domain: shop.toLowerCase(), apiVersion }, jwtSecretKey);
// Token returned to frontend via redirect params

// In frontend — JWT stored in component state or redux
// All API calls:
const res = await repositoryApi.get('/data', { headers: { Authorization: `Bearer ${jwt}` } });
```

## Page (Route) Pattern

```jsx
// pages/feature/index.jsx
import { Page, BlockStack } from '@shopify/polaris';
import FeatureHeader from '@/components/FeatureHeader';
import useFeatureSWR from '@/hooks/useFeatureSWR';
import { useSelector } from 'react-redux';
import { selectShop } from '@/redux/reducers/general.reducer';

export default function FeaturePage() {
    const { jwt } = useSelector(selectShop);
    const { data, isLoading } = useFeatureSWR({ jwt });

    return (
        <Page title="Feature">
            <BlockStack gap="400">
                <FeatureHeader data={data} loading={isLoading} />
            </BlockStack>
        </Page>
    );
}
```

Pages are auto-discovered via `import.meta.globEager('./pages/**/index.jsx')` in `App.jsx` — no manual route registration.

## Add Feature Checklist

1. **Component** → `components/FeatureName/index.jsx` + `style.module.css`
2. **Service** → `services/api/feature.service.js` + export from `services/index.js`
3. **Hook** → `hooks/useFeatureName.js` (SWR or plain React hooks)
4. **State** (if needed) → `redux/reducers/feature.reducer.js` + `redux/sagas/feature.saga.js`
5. **Register saga** in `redux/sagas/index.js`
6. **Page** → `pages/feature/index.jsx` (auto-discovered)
7. **Constants** → `consts/Feature.const.js`

## Strict Rules

- Do **not** use custom UI components where Polaris equivalents exist
- Do **not** access Redux state directly from services — services are pure async functions
- Do **not** dispatch sagas from inside other sagas without yielding
- Do **not** use `var` or class components — use functional components with hooks
- Do **not** add environment variables without `VITE_` prefix for frontend use
- Do **not** hard-code API URLs — use `SERVER_URL` from env config
- Preserve existing API response key names — frontend depends on exact field names

## Verification

```sh
cd mida-cms
pnpm run lint
pnpm run build  # Check for TypeScript/build errors
```
