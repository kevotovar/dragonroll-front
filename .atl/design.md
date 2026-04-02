# Design: Dockerfile and Docker Compose Setup

## Technical Approach

Create a production-ready, multi-stage Docker build for the WooNuxt Nuxt.js 3 frontend. The design prioritizes:

1. **Multi-stage builds** for minimal production image size (~150MB target)
2. **Bun** for fast dependency installation and runtime
3. **Build-time environment injection** since Nuxt requires env vars during `nuxt build`
4. **Non-root execution** for container security
5. **Layer caching optimization** for faster rebuilds

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           DOCKER BUILD CONTEXT                          │
├─────────────────────────────────────────────────────────────────────────┤
│  Stage 1: deps (oven/bun:1-alpine)                                      │
│  ├── Install bun dependencies (bun.lock copied first for cache)         │
│  └── Output: node_modules/                                              │
│                                                                         │
│  Stage 2: builder (oven/bun:1-alpine)                                   │
│  ├── Copy dependencies from deps                                        │
│  ├── Copy source code                                                   │
│  ├── Inject build-time env vars (ARG)                                   │
│  ├── Run nuxt build                                                     │
│  └── Output: .output/                                                   │
│                                                                         │
│  Stage 3: production (node:22-alpine)                                   │
│  ├── Copy built application from builder                                │
│  ├── Create non-root user (node:node)                                   │
│  ├── Set up health check                                                │
│  └── Output: Runnable production container (~150MB)                     │
└─────────────────────────────────────────────────────────────────────────┘
```

## Architecture Decisions

### Decision: Bun Over Node.js/npm

| Option | Tradeoff                                        | Decision |
| ------ | ----------------------------------------------- | -------- |
| Bun    | Faster install, smaller lockfile, modern        | Selected |
| npm    | Standard, slower installs                       | Rejected |
| pnpm   | Good disk efficiency, requires separate install | Rejected |

**Rationale**: Project already uses Bun (bun.lock exists). Bun offers 2-3x faster package installation and is fully compatible with Node.js ecosystem.

### Decision: Base Image Selection

| Stage        | Image             | Reason                                          |
| ------------ | ----------------- | ----------------------------------------------- |
| deps/builder | oven/bun:1-alpine | Official Bun image, minimal Alpine base (~70MB) |
| production   | node:22-alpine    | Matches .nvmrc (22.17.1), production-tested     |

**Rationale**: Node 22 Alpine for production avoids potential Bun runtime edge cases in production while keeping image small (~40MB base).

### Decision: Multi-Stage Build Strategy

| Stage      | Purpose              | Cached When               |
| ---------- | -------------------- | ------------------------- |
| deps       | Install dependencies | bun.lock unchanged        |
| builder    | Compile Nuxt app     | Source code changes       |
| production | Serve static app     | Only when builder changes |

**Rationale**: Separating deps from builder allows Docker layer caching to skip `bun install` when only source code changes.

### Decision: Build-Time vs Runtime Env Vars

| Variable           | Type             | Reason                                   |
| ------------------ | ---------------- | ---------------------------------------- |
| GQL_HOST           | Build-time (ARG) | Nuxt embeds GraphQL config at build time |
| NUXT_IMAGE_DOMAINS | Build-time (ARG) | Image domains configured in nuxt.config  |
| APP_HOST           | Build-time (ARG) | Used in runtimeConfig headers            |
| CATALOG_ISR_TTL    | Build-time (ARG) | Used in nitro routeRules at build        |
| NUXT*PUBLIC*\*     | Build-time (ARG) | Client-side variables baked into bundle  |
| PRIMARY_COLOR      | Build-time (ARG) | CSS variable, processed at build         |

**Rationale**: Nuxt 3 SSR applications embed most configuration during build. Runtime env vars require NUXT*PUBLIC* prefix AND must be defined at build to appear in client bundle.

### Decision: Non-Root User

**Choice**: Run as nuxt user (uid: 1001, gid: 1001)
**Implementation**: Production stage creates/chowns app directory, container starts as non-root
**Rationale**: Industry standard for container security. Prevents privilege escalation attacks.

### Decision: Health Check Strategy

**Choice**: HTTP health check on localhost:3000
**Interval**: 30s, Timeout: 3s, Retries: 3
**Rationale**: Nuxt 3 preview server responds on all routes. Simple HTTP 200 on / is sufficient.

## File Changes

| File               | Action | Description                                         |
| ------------------ | ------ | --------------------------------------------------- |
| Dockerfile         | Create | Multi-stage container definition with Bun + Node 22 |
| docker-compose.yml | Create | Production orchestration with env var injection     |
| .dockerignore      | Create | Exclude node_modules, .git, .env, dev files         |
| .env.example       | Modify | Add Docker-related documentation and examples       |

## Dockerfile Design

### Stage 1: Dependencies

```dockerfile
FROM oven/bun:1-alpine AS deps
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
```

Key points: --frozen-lockfile ensures reproducible builds. Only package files copied first enables cache hits when source changes.

### Stage 2: Builder

```dockerfile
FROM oven/bun:1-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ARG GQL_HOST
ARG NUXT_IMAGE_DOMAINS
ARG APP_HOST
ARG CATALOG_ISR_TTL
ARG NUXT_PUBLIC_PRODUCTS_PER_PAGE
ARG NUXT_PUBLIC_STRIPE_PUBLISHABLE_KEY
ARG PRIMARY_COLOR
ENV GQL_HOST=${GQL_HOST}
ENV NUXT_IMAGE_DOMAINS=${NUXT_IMAGE_DOMAINS}
ENV APP_HOST=${APP_HOST}
ENV CATALOG_ISR_TTL=${CATALOG_ISR_TTL}
ENV NUXT_PUBLIC_PRODUCTS_PER_PAGE=${NUXT_PUBLIC_PRODUCTS_PER_PAGE}
ENV NUXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=${NUXT_PUBLIC_STRIPE_PUBLISHABLE_KEY}
ENV PRIMARY_COLOR=${PRIMARY_COLOR}
RUN bun run build
```

Key points: All env vars passed as ARG then converted to ENV. Build fails if GQL_HOST not provided.

### Stage 3: Production

```dockerfile
FROM node:22-alpine AS production
WORKDIR /app
RUN addgroup -g 1001 -S nodejs && adduser -S nuxt -u 1001
COPY --from=builder --chown=nuxt:nodejs /app/.output ./.output
USER nuxt
EXPOSE 3000
ENV PORT=3000
ENV HOST=0.0.0.0
ENV NODE_ENV=production
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"
CMD ["node", ".output/server/index.mjs"]
```

Key points: Uses Node.js 22 (matches .nvmrc) instead of Bun for stability. Non-root user nuxt with proper ownership.

## Docker Compose Design

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        GQL_HOST: ${GQL_HOST}
        NUXT_IMAGE_DOMAINS: ${NUXT_IMAGE_DOMAINS}
        APP_HOST: ${APP_HOST:-http://localhost:3000}
        CATALOG_ISR_TTL: ${CATALOG_ISR_TTL:-3600}
        NUXT_PUBLIC_PRODUCTS_PER_PAGE: ${NUXT_PUBLIC_PRODUCTS_PER_PAGE:-24}
        NUXT_PUBLIC_STRIPE_PUBLISHABLE_KEY: ${NUXT_PUBLIC_STRIPE_PUBLISHABLE_KEY}
        PRIMARY_COLOR: ${PRIMARY_COLOR:-#ff0000}
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=production
    restart: unless-stopped
    healthcheck:
      test:
        [
          "CMD",
          "node",
          "-e",
          "require('http').get('http://localhost:3000', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})",
        ]
      interval: 30s
      timeout: 3s
      retries: 3
```

Key points: Build args receive env vars from host environment or .env file. Port mapping exposes container port 3000 to host.

## .dockerignore Design

```
# Dependencies
node_modules

# Build outputs
.output
.nuxt
.cache
dist

# Development files
.env
.env.*
!.env.example
.git
.github
.vscode
.idea
.fleet

# Logs
logs
*.log

# Misc
.DS_Store
*.pem
woonuxt-settings

# Nuxt/Netlify
.netlify
.data
.nitro
```

## Testing Strategy

| Layer       | What to Test                  | Approach                                    |
| ----------- | ----------------------------- | ------------------------------------------- |
| Build       | Image builds successfully     | `docker build --build-arg GQL_HOST=test...` |
| Integration | Container starts and responds | `docker-compose up` + curl localhost:3000   |
| Health      | Health check passes           | Docker health status shows healthy          |

## Migration / Rollout

No migration required. This is a new feature adding Docker support.

### Rollout Steps:

1. Create .env file from .env.example with production values
2. Run `docker-compose up --build` to test locally
3. Deploy to production server with `docker-compose up -d`

## Open Questions

None. Design is ready for implementation.
