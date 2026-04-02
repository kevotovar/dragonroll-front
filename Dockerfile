# =============================================================================
# DragonRoll Frontend - Multi-Stage Docker Build
# =============================================================================
# 
# This Dockerfile implements a three-stage build process:
#   1. deps: Install dependencies using Bun
#   2. builder: Build the Nuxt application
#   3. production: Serve the built application with Node.js
#
# IMPORTANT: BUILD-TIME REQUIREMENT
#   The WooNuxt application requires a LIVE GraphQL endpoint during build.
#   The nuxt-graphql-client module introspects the schema at build time.
#   Therefore, GQL_HOST must point to a real, accessible WordPress GraphQL
#   endpoint when building this image.
#
#   For CI/CD pipelines, ensure the WordPress backend is accessible or
#   consider using a pre-built schema file approach (advanced).
#
# Build arguments (all environment variables must be provided at build time):
#   - GQL_HOST (required): WordPress GraphQL endpoint (MUST be accessible during build)
#   - NUXT_IMAGE_DOMAINS (required): Comma-separated image domains
#   - APP_HOST (optional): Origin header for WordPress API
#   - CATALOG_ISR_TTL (optional): ISR cache lifetime
#   - NUXT_PUBLIC_PRODUCTS_PER_PAGE (optional): Products per page
#   - NUXT_PUBLIC_STRIPE_PUBLISHABLE_KEY (optional): Stripe publishable key
#   - PRIMARY_COLOR (optional): Primary UI color
#
# Usage:
#   # Build (requires real GraphQL endpoint)
#   docker build \
#     --build-arg GQL_HOST=https://wp.example.com/graphql \
#     --build-arg NUXT_IMAGE_DOMAINS=wp.example.com \
#     -t dragonroll-front:latest .
#
#   # Run
#   docker run -d -p 3000:3000 --name dragonroll-front dragonroll-front:latest
#
# =============================================================================

# =============================================================================
# STAGE 1: Dependencies
# =============================================================================
# Use Bun for fast dependency installation
FROM oven/bun:1-alpine AS deps

# Set working directory
WORKDIR /app

# Copy lock file and package.json first for better layer caching
# The lock file must be copied before package.json for Bun to use it
COPY bun.lock package.json ./

# Install dependencies using frozen lockfile for reproducible builds
# This ensures the exact same versions are installed every time
RUN bun install --frozen-lockfile

# =============================================================================
# STAGE 2: Builder
# =============================================================================
# Use same Bun image for building the application
FROM oven/bun:1-alpine AS builder

# Set working directory
WORKDIR /app

# Copy dependencies from deps stage
COPY --from=deps /app/node_modules ./node_modules

# =============================================================================
# Build Arguments - All environment variables for Nuxt build
# =============================================================================
# Required environment variables
ARG GQL_HOST
ARG NUXT_IMAGE_DOMAINS

# Optional environment variables with defaults
ARG APP_HOST=http://localhost:3000
ARG CATALOG_ISR_TTL=3600
ARG NUXT_PUBLIC_PRODUCTS_PER_PAGE=24
ARG NUXT_PUBLIC_STRIPE_PUBLISHABLE_KEY
ARG PRIMARY_COLOR=#ff0000
ARG NODE_ENV=production

# Validate required build arguments
RUN if [ -z "$GQL_HOST" ]; then echo "ERROR: GQL_HOST build argument is required" && exit 1; fi
RUN if [ -z "$NUXT_IMAGE_DOMAINS" ]; then echo "ERROR: NUXT_IMAGE_DOMAINS build argument is required" && exit 1; fi

# Copy source code
COPY . .

# Build the Nuxt application
# NOTE: This requires the GQL_HOST endpoint to be accessible!
# The nuxt-graphql-client module introspects the schema during build.
RUN bun run build

# =============================================================================
# STAGE 3: Production
# =============================================================================
# Use Node.js for production (smaller runtime, no need for Bun in production)
FROM node:22-alpine AS production

# Install dumb-init for proper signal handling and curl for health checks
RUN apk add --no-cache dumb-init curl

# Create non-root user for security
# UID 1001 is chosen to avoid conflicts with common system users
RUN addgroup -g 1001 -S nuxt && \
    adduser -u 1001 -S nuxt -G nuxt

# Set working directory
WORKDIR /app

# Copy built application from builder stage
# The .output directory contains the built Nuxt application
COPY --from=builder --chown=nuxt:nuxt /app/.output ./.output

# Set proper ownership
RUN chown -R nuxt:nuxt /app

# Switch to non-root user
USER nuxt

# Expose the port the app runs on
EXPOSE 3000

# Set environment variables for runtime
ENV NODE_ENV=production \
    PORT=3000 \
    HOST=0.0.0.0

# Health check to verify the application is running
# Uses curl to check if the server responds on port 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:3000/ || exit 1

# Use dumb-init to handle signals properly
# This ensures graceful shutdown when the container is stopped
ENTRYPOINT ["dumb-init", "--"]

# Start the Nuxt server
# The .output/server/index.mjs is the entry point generated by Nuxt
CMD ["node", ".output/server/index.mjs"]
