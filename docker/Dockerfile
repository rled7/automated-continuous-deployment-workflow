# ─── Stage 1: Dependencies ────────────────────────────────────────────────────
# Build 019: BuildKit cache mounts on npm install steps avoid re-downloading the
# npm cache on every build. The /root/.npm cache is preserved across builds when
# the image is built with `docker buildx build` (BuildKit is the default backend).
# For multi-arch builds (linux/amd64,linux/arm64) each platform gets its own
# cache namespace automatically via the platform-specific build context.
FROM node:25-alpine AS deps
WORKDIR /app

# Install only production dependencies first (layer cache optimization)
COPY app/package*.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --only=production --ignore-scripts && \
    cp -R node_modules /tmp/prod_modules

# Install all deps (including dev) for build
RUN --mount=type=cache,target=/root/.npm \
    npm ci --ignore-scripts

# ─── Stage 2: Build ───────────────────────────────────────────────────────────
FROM node:25-alpine AS builder
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY app/ .

RUN npm run build

# ─── Stage 3: Production Image ────────────────────────────────────────────────
FROM node:25-alpine AS runner
WORKDIR /app

# Security: non-root user
RUN addgroup --system --gid 1001 appgroup && \
    adduser  --system --uid 1001 appuser

# Copy only what's needed at runtime
COPY --from=deps    /tmp/prod_modules     ./node_modules
COPY --from=builder /app/dist             ./dist
COPY --from=builder /app/package.json     ./package.json

# Health check — used by Kubernetes liveness/readiness probes
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:3000/health/live || exit 1

# Drop all capabilities except what's needed
USER appuser

EXPOSE 3000

ENV NODE_ENV=production \
    PORT=3000

CMD ["node", "dist/server.js"]
