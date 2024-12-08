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

# Root operations first
RUN adduser --uid 1001 --disabled-password --gecos "" appuser && \
    mkdir -p \
        /app/packages/server/src \
        /app/migrations \
        /app/client \
        /app/node_modules \
        /home/appuser/.npm-global && \
    chown -R appuser:appuser /app /home/appuser && \
    chmod -R 755 /app

# Copy files and configs first
COPY --chown=appuser:appuser docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

# Create TypeORM config with proper DataSource instance
RUN echo "const { DataSource } = require('typeorm');\n\
const path = require('path');\n\
\n\
const AppDataSource = new DataSource({\n\
  type: 'postgres',\n\
  host: process.env.DB_HOST || 'localhost',\n\
  port: parseInt(process.env.DB_PORT) || 5432,\n\
  username: process.env.DB_USER || 'postgres',\n\
  password: process.env.DB_PASSWORD || 'postgres',\n\
  database: process.env.DB_NAME || 'laudspeaker',\n\
  entities: [path.join(__dirname, 'dist/**/*.entity.{js,ts}')],\n\
  migrations: [path.join(__dirname, 'migrations/*.{js,ts}')],\n\
  migrationsTableName: 'migrations',\n\
  migrationsRun: true,\n\
  logging: process.env.NODE_ENV === 'production' \n\
    ? ['error', 'warn']  // Production logging\n\
    : ['query', 'error', 'warn'],  // Development logging\n\
  synchronize: false\n\
});\n\
\n\
module.exports = AppDataSource;" > /app/typeorm.config.js && \
    chown appuser:appuser /app/typeorm.config.js && \
    chmod 644 /app/typeorm.config.js

# Copy artifacts in correct order
COPY --chown=appuser:appuser --from=base /app/package*.json ./
COPY --chown=appuser:appuser --from=base /app/packages/server/package*.json ./packages/server/
COPY --chown=appuser:appuser --from=frontend /app/packages/client/build ./client/
COPY --chown=appuser:appuser --from=backend /app/packages/server/dist ./dist/
COPY --chown=appuser:appuser --from=backend /app/packages/server/node_modules ./node_modules/
COPY --chown=appuser:appuser --from=backend /app/packages/server/src/data-source.ts ./packages/server/src/
COPY --chown=appuser:appuser scripts ./scripts/
COPY --chown=appuser:appuser packages/server/migrations/* ./migrations/

# Create package.json with type: module
RUN echo '{"type":"module"}' > package.json && \
    chown appuser:appuser package.json

USER appuser

# Set environment without experimental flags
ENV PATH="/home/appuser/.npm-global/bin:$PATH" \
    NPM_CONFIG_PREFIX=/home/appuser/.npm-global \
    NODE_ENV=production

# Install global packages without ESM
RUN unset NODE_OPTIONS && \
    npm config set prefix '/home/appuser/.npm-global' && \
    npm install -g typescript@4.9.5 && \
    npm install -g tslib@2.6.2 && \
    npm install -g ts-node@10.9.1 && \
    npm install -g typeorm@0.3.17 && \
    npm install -g clickhouse-migrations@1.0.0 && \
    npm install -g @types/node@18.18.0

# Now set NODE_OPTIONS for runtime
ENV NODE_OPTIONS="--es-module-specifier-resolution=node"

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT:-3000}/health || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
