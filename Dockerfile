# To build: docker build -f Dockerfile -t laudspeaker/laudspeaker:latest .
# To run: docker run -it -p 80:80 --env-file packages/server/.env --rm laudspeaker/laudspeaker:latest

# Base stage for shared dependencies
FROM node:18-slim AS base
WORKDIR /app
COPY package*.json ./
COPY packages/client/package*.json ./packages/client/
COPY packages/server/package*.json ./packages/server/

# Debug: Check if package.json exists in base stage
RUN ls -la /app/package.json || echo "No package.json in base"

# Frontend build stage
FROM node:18-slim AS frontend
ARG EXTERNAL_URL
ARG FRONTEND_SENTRY_AUTH_TOKEN
ARG FRONTEND_SENTRY_ORG=laudspeaker-rb
ARG FRONTEND_SENTRY_PROJECT=javascript-react
ARG FRONTEND_SENTRY_DSN_URL=https://2444369e8e13b39377ba90663ae552d1@o4506038702964736.ingest.sentry.io/4506038705192960
ARG REACT_APP_POSTHOG_HOST
ARG REACT_APP_POSTHOG_KEY
ARG REACT_APP_ONBOARDING_API_KEY

# Set build-time environment variables
ENV SENTRY_AUTH_TOKEN=${FRONTEND_SENTRY_AUTH_TOKEN} \
    SENTRY_ORG=${FRONTEND_SENTRY_ORG} \
    SENTRY_PROJECT=${FRONTEND_SENTRY_PROJECT} \
    REACT_APP_SENTRY_DSN_URL_FRONTEND=${FRONTEND_SENTRY_DSN_URL} \
    REACT_APP_WS_BASE_URL=${EXTERNAL_URL} \
    REACT_APP_POSTHOG_HOST=${REACT_APP_POSTHOG_HOST} \
    REACT_APP_POSTHOG_KEY=${REACT_APP_POSTHOG_KEY} \
    REACT_APP_ONBOARDING_API_KEY=${REACT_APP_ONBOARDING_API_KEY} \
    NODE_OPTIONS="--max-old-space-size=4096" \
    NODE_ENV=production \
    TS_NODE_TRANSPILE_ONLY=true

WORKDIR /app
COPY --from=base /app ./
COPY packages/client ./packages/client

# Install frontend dependencies and build
RUN cd packages/client && \
    npm ci --legacy-peer-deps && \
    npm install --save-dev @babel/plugin-proposal-private-property-in-object @types/react-helmet && \
    npm install --save react-helmet && \
    echo "declare module 'react-helmet';" > react-helmet.d.ts && \
    # Create production environment file
    echo "REACT_APP_API_URL=${EXTERNAL_URL:-http://localhost:3000}" > .env.prod && \
    echo "REACT_APP_WS_BASE_URL=${EXTERNAL_URL:-http://localhost:3000}" >> .env.prod && \
    echo "REACT_APP_POSTHOG_HOST=${REACT_APP_POSTHOG_HOST:-}" >> .env.prod && \
    echo "REACT_APP_POSTHOG_KEY=${REACT_APP_POSTHOG_KEY:-}" >> .env.prod && \
    echo "REACT_APP_ONBOARDING_API_KEY=${REACT_APP_ONBOARDING_API_KEY:-}" >> .env.prod && \
    # Build frontend
    DISABLE_ESLINT_PLUGIN=true \
    EXTEND_ESLINT=false \
    ESLINT_NO_DEV_ERRORS=true \
    GENERATE_SOURCEMAP=false \
    TSC_COMPILE_ON_ERROR=true \
    CI=false \
    npm run build:prod

# Handle frontend source maps conditionally
RUN cd packages/client && \
    if [ -n "$FRONTEND_SENTRY_AUTH_TOKEN" ] ; then \
        SENTRY_RELEASE=$(./node_modules/.bin/sentry-cli releases propose-version) && \
        echo $SENTRY_RELEASE > /app/SENTRY_RELEASE && \
        REACT_APP_SENTRY_RELEASE=$SENTRY_RELEASE npm run build:client:sourcemaps ; \
    else \
        echo "development" > /app/SENTRY_RELEASE ; \
    fi

# Backend build stage
FROM node:18-slim AS backend
WORKDIR /app

# Create TypeScript declarations first
# Create TypeScript declarations first
RUN mkdir -p /app/packages/server/src/@types && \
    echo 'import { User } from "../entities/user.entity";\n\
\n\
declare global {\n\
  namespace Express {\n\
    interface Request {\n\
      user?: User;\n\
    }\n\
    interface User extends User {}\n\
  }\n\
}' > /app/packages/server/src/@types/express.d.ts

# Copy base files including package.json
COPY --from=base /app ./
COPY package*.json ./
COPY packages/server/package*.json ./packages/server/

# Copy server source
COPY packages/server ./packages/server

# Verify files exist
RUN ls -la /app/package.json && \
    ls -la /app/packages/server/package.json && \
    ls -la /app/packages/server/src/@types/express.d.ts

# Install dependencies and build
RUN cd packages/server && \
    npm ci && \
    npm run build

# Verify build artifacts
RUN ls -la /app/packages/server/dist

# Copy Sentry release file from frontend build
COPY --from=frontend /app/SENTRY_RELEASE ./SENTRY_RELEASE

# Debug: Check if package.json exists in backend stage
RUN ls -la /app/package.json || echo "No package.json in backend"

# Final stage
FROM node:18-slim AS final
WORKDIR /app

# Switch to root to create user and set up directories
USER root

# Create user and set up directories with proper permissions
RUN adduser --uid 1001 --disabled-password --gecos "" appuser && \
    mkdir -p /app/packages/server/src /app/migrations /app/client /home/appuser/.npm-global && \
    mkdir -p /app/node_modules && \
    chown -R 1001:1001 /app /home/appuser && \
    chmod -R 777 /app/node_modules  # Ensure full permissions for node_modules

# Copy files with correct ownership
COPY --chown=1001:1001 --from=backend /app/packages/server/dist ./dist
COPY --chown=1001:1001 --from=backend /app/packages/server/node_modules ./node_modules
COPY --chown=1001:1001 --from=frontend /app/packages/client/build ./client
COPY --chown=1001:1001 package.json ./

# Set permissions again after copying
RUN chown -R 1001:1001 /app && \
    chmod -R 777 /app/node_modules

# Switch to non-root user
USER appuser

# Configure npm for the non-root user
RUN npm config set prefix '/home/appuser/.npm-global' && \
    npm install -g clickhouse-migrations typeorm typescript ts-node @types/node

# Copy files with correct ownership
COPY --chown=1001:1001 --from=backend /app/packages/server/dist ./dist
COPY --chown=1001:1001 --from=backend /app/packages/server/node_modules ./node_modules
COPY --chown=1001:1001 --from=frontend /app/packages/client/build ./client
COPY --chown=1001:1001 package.json ./

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

# Debug: Check if package.json exists in final stage
RUN ls -la /app/package.json || echo "No package.json in final"

# Copy package files first
COPY --from=base /app/package*.json ./
COPY --from=base /app/packages/server/package*.json ./packages/server/

# Copy build artifacts 
COPY --from=frontend /app/packages/client/build ./client
COPY --from=backend /app/packages/server/dist ./dist
COPY --from=backend /app/packages/server/node_modules ./node_modules
COPY --from=backend /app/packages/server/src/data-source.ts ./packages/server/src/
COPY --from=frontend /app/SENTRY_RELEASE ./
COPY scripts ./scripts
COPY packages/server/migrations/* ./migrations/
COPY docker-entrypoint.sh ./

# Switch back to root for operations requiring elevated permissions
USER root

RUN chmod +x docker-entrypoint.sh && \
    chmod -R 755 /app/migrations && \
    rm -f /usr/local/bin/clickhouse-migrations && \
    ln -s /home/appuser/.npm-global/bin/clickhouse-migrations /usr/local/bin/clickhouse-migrations && \
    npm cache clean --force && \
    rm -rf /home/appuser/.npm/* && \
    mkdir -p /home/appuser/.npm && \
    chown -R 1001:1001 /home/appuser/.npm && \
    chmod -R 775 /home/appuser/.npm

# Switch back to non-root user for remaining operations
USER appuser

# Pre-create the npm cache directory with correct permissions
RUN mkdir -p /home/appuser/.npm && \
    npm config set cache /home/appuser/.npm --global

# Verify PATH and installations
RUN echo "PATH=$PATH" && \
    which clickhouse-migrations && \
    which typeorm && \
    which ts-node

# Configure container
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT:-3000}/health || exit 1

# Set up final permissions and user
USER 1001

ENTRYPOINT ["./docker-entrypoint.sh"]

RUN ls -la /home/appuser/.npm-global/bin
