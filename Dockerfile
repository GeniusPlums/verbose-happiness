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

# Install TypeORM and required dependencies locally
COPY --chown=appuser:appuser package*.json ./
RUN npm install --legacy-peer-deps \
    # Core dependencies
    typeorm@0.3.17 \
    pg@8.11.3 \
    class-transformer@0.5.1 \
    class-validator@0.14.0 \
    class-sanitizer@1.0.1 \
    uid@2.0.2 \
    iterare@1.2.1 \
    bcryptjs@2.4.3 \
    mongoose@7.6.3 \
    tst-reflect@0.7.4 \
    csv-parse@5.5.0 \
    @slack/oauth@2.6.1 \
    amqplib@0.10.3 \
    bullmq@4.12.4 \
    mailgun.js@9.3.0 \
    liquidjs@10.9.2 \
    @sendgrid/mail@7.7.0 \
    @sendgrid/eventwebhook@7.7.0 \
    svix@1.0.0 \
    # NestJS dependencies (all version 9.x)
    @nestjs/websockets@9.4.0 \
    @nestjs/platform-socket.io@9.4.0 \
    @nestjs/platform-express@9.0.0 \
    @nestjs/common@9.0.0 \
    @nestjs/core@9.0.0 \
    @nestjs/config@2.3.0 \
    @nestjs/typeorm@9.0.1 \
    @nestjs/jwt@9.0.0 \
    @nestjs/passport@9.0.3 \
    @nestjs/mongoose@9.2.2 \
    @nestjs/bullmq@10.0.1 \
    passport@0.6.0 \
    # Additional utilities
    socket.io@4.7.2 \
    reflect-metadata@0.1.13 \
    rxjs@7.8.1 \
    cache-manager@5.2.4 \
    nest-winston@1.9.4 \
    winston@3.11.0

# Create TypeORM config with proper DataSource instance
RUN echo "const { DataSource } = require('typeorm');\n\
const path = require('path');\n\
\n\
const dataSource = new DataSource({\n\
 type: 'postgres',\n\
 host: process.env.DB_HOST,\n\
 port: parseInt(process.env.DB_PORT || '5432'),\n\
 username: process.env.DB_USER,\n\
 password: process.env.DB_PASSWORD,\n\
 database: process.env.DB_NAME,\n\
 entities: [path.join(__dirname, 'dist/**/*.entity.{js,ts}')],\n\
 migrations: [path.join(__dirname, 'migrations/*.{js,ts}')],\n\
 migrationsTableName: 'migrations',\n\
 migrationsRun: true,\n\
 logging: process.env.NODE_ENV === 'production' \n\
   ? ['error', 'warn']  // Production logging\n\
   : ['query', 'error', 'warn'],  // Development logging\n\
 synchronize: false,\n\
 ssl: process.env.DB_SSL === 'true' ? {\n\
   rejectUnauthorized: false\n\
 } : false\n\
});\n\
\n\
module.exports = dataSource;\n\
module.exports.default = dataSource;" > /app/typeorm.config.cjs && \
   chown appuser:appuser /app/typeorm.config.cjs && \
   chmod 644 /app/typeorm.config.cjs

# Copy artifacts in correct order
COPY --chown=appuser:appuser --from=base /app/package*.json ./
COPY --chown=appuser:appuser --from=base /app/packages/server/package*.json ./packages/server/
COPY --chown=appuser:appuser --from=frontend /app/packages/client/build ./client/
COPY --chown=appuser:appuser --from=backend /app/packages/server/dist ./dist/
COPY --chown=appuser:appuser --from=backend /app/packages/server/node_modules ./node_modules/
COPY --chown=appuser:appuser --from=backend /app/packages/server/src/data-source.ts ./packages/server/src/
COPY --chown=appuser:appuser scripts ./scripts/
COPY --chown=appuser:appuser packages/server/migrations/* ./migrations/

USER appuser

ENV PATH="/home/appuser/.npm-global/bin:$PATH" \
   NPM_CONFIG_PREFIX=/home/appuser/.npm-global \
   NODE_ENV=production \
   TYPEORM_CONFIG=/app/typeorm.config.cjs \
   TS_NODE_PROJECT=tsconfig.json

# Install global packages
RUN npm config set prefix '/home/appuser/.npm-global' && \
   npm install -g \
   typescript@4.9.5 \
   tslib@2.6.2 \
   ts-node@10.9.1 \
   typeorm@0.3.17 \
   clickhouse-migrations@1.0.0 \
   @types/node@18.18.0 \
   class-transformer@0.5.1 \
   class-validator@0.14.0 \
   uid@2.0.2 \
   iterare@1.2.1

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
   CMD curl -f http://localhost:${PORT:-3000}/health || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
