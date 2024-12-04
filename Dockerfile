# To build: docker build -f Dockerfile -t laudspeaker/laudspeaker:latest .
# To run: docker run -it -p 80:80 --env-file packages/server/.env --rm laudspeaker/laudspeaker:latest

# Base stage for shared dependencies
FROM node:18-slim AS base
WORKDIR /app
COPY package*.json ./
COPY packages/client/package*.json ./packages/client/
COPY packages/server/package*.json ./packages/server/

# Frontend build stage
# ... (previous frontend_build stage remains the same until backend_build) ...

# Backend build stage
FROM node:18-slim AS backend_build
WORKDIR /app

# Copy necessary files
COPY --from=base /app ./
COPY packages/server ./packages/server
COPY packages/server/src ./packages/server/src
COPY packages/server/src/data-source.ts ./packages/server/src/data-source.ts

# Debug: List contents to verify files
RUN ls -la /app/packages/server/src/data-source.ts || echo "data-source.ts not found!" && \
    ls -la /app/packages/server/src/

# Install dependencies and build backend
RUN cd packages/server && \
    npm ci && \
    npm run build

# Copy Sentry release file from frontend build
COPY --from=frontend_build /app/SENTRY_RELEASE ./SENTRY_RELEASE

# Final stage
FROM node:18-slim AS final
ARG BACKEND_SENTRY_DSN_URL=https://15c7f142467b67973258e7cfaf814500@o4506038702964736.ingest.sentry.io/4506040630640640
ARG EXTERNAL_URL

# Set runtime environment variables
ENV SENTRY_DSN_URL_BACKEND=${BACKEND_SENTRY_DSN_URL} \
    NODE_ENV=production \
    ENVIRONMENT=production \
    SERVE_CLIENT_FROM_NEST=true \
    CLIENT_PATH=/app/client \
    FRONTEND_URL=${EXTERNAL_URL:-http://localhost:3000} \
    POSTHOG_HOST=https://app.posthog.com \
    POSTHOG_KEY=RxdBl8vjdTwic7xTzoKTdbmeSC1PCzV6sw-x-FKSB-k \
    DATABASE_URL=postgres://postgres:postgres@localhost:5432/laudspeaker \
    PATH="/home/appuser/.npm-global/bin:$PATH" \
    NPM_CONFIG_PREFIX=/home/appuser/.npm-global \
    CLICKHOUSE_DB=default

WORKDIR /app

# Create necessary directories and set up permissions
RUN mkdir -p /app/packages/server/src /app/migrations /app/client /home/appuser/.npm-global && \
    # Add non-root user
    adduser --disabled-password --gecos "" appuser && \
    chown -R appuser:appuser /home/appuser && \
    # Set up npm global directory for non-root user
    mkdir -p /home/appuser/.npm-global/lib && \
    chown -R appuser:appuser /home/appuser/.npm-global && \
    # Install global dependencies
    npm config set prefix '/home/appuser/.npm-global' && \
    npm install -g clickhouse-migrations typeorm typescript ts-node @types/node && \
    # Set proper permissions for app directory
    chown -R appuser:appuser /app

# Copy build artifacts and configurations
COPY --from=frontend_build /app/packages/client/build ./client
COPY --from=backend_build /app/packages/server/dist ./dist
COPY --from=backend_build /app/packages/server/node_modules ./node_modules
COPY --from=backend_build /app/packages/server/src/data-source.ts ./packages/server/src/
COPY --from=frontend_build /app/SENTRY_RELEASE ./SENTRY_RELEASE
COPY scripts ./scripts
COPY packages/server/migrations/* ./migrations/
COPY docker-entrypoint.sh ./

# Set permissions for entrypoint and other files
RUN chmod +x docker-entrypoint.sh && \
    chown -R appuser:appuser /app && \
    # Explicitly set permissions for migrations directory
    chmod -R 755 /app/migrations && \
    # Create symlink for clickhouse-migrations
    ln -s /home/appuser/.npm-global/bin/clickhouse-migrations /usr/local/bin/clickhouse-migrations

# Switch to non-root user
USER appuser

# Verify PATH and installations
RUN echo "PATH=$PATH" && \
    which clickhouse-migrations && \
    which typeorm && \
    which ts-node

# Configure container
EXPOSE 80
ENTRYPOINT ["./docker-entrypoint.sh"]
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT:-3000}/health || exit 1