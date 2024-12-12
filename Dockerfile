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
    echo "REACT_APP_API_URL=${EXTERNAL_URL:-http://localhost:3000}" > .env.prod && \
    echo "REACT_APP_WS_BASE_URL=${EXTERNAL_URL:-http://localhost:3000}" >> .env.prod && \
    echo "REACT_APP_POSTHOG_HOST=${REACT_APP_POSTHOG_HOST:-}" >> .env.prod && \
    echo "REACT_APP_POSTHOG_KEY=${REACT_APP_POSTHOG_KEY:-}" >> .env.prod && \
    echo "REACT_APP_ONBOARDING_API_KEY=${REACT_APP_ONBOARDING_API_KEY:-}" >> .env.prod && \
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

# Install dependencies and build
RUN cd packages/server && \
    npm ci && \
    npm run build

# Final stage
FROM node:18-slim AS final
WORKDIR /app

# Install curl and create directories
RUN apt-get update && \
    apt-get install -y curl && \
    rm -rf /var/lib/apt/lists/* && \
    adduser --uid 1001 --disabled-password --gecos "" appuser && \
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

# Install all dependencies from package.json
COPY --chown=appuser:appuser package*.json ./
RUN npm install --legacy-peer-deps \
    # NestJS Core Dependencies
    @nestjs/common@^10.0.0 \
    @nestjs/config@^2.3.0 \
    @nestjs/core@^9.0.0 \
    @nestjs/jwt@^9.0.0 \
    @nestjs/mongoose@^9.2.0 \
    @nestjs/passport@^9.0.3 \
    @nestjs/platform-express@^9.0.0 \
    @nestjs/platform-socket.io@^9.4.0 \
    @nestjs/schedule@^2.1.0 \
    @nestjs/serve-static@3.0.1 \
    @nestjs/typeorm@^9.0.1 \
    @nestjs/websockets@^9.4.0 \
    @nestjs/bullmq@^1.1.0 \
    @nestjs/cache-manager@^2.2.0 \
    @nestjs/mapped-types@^1.2.2 \
    
    # Database & ORM
    typeorm@^0.3.12 \
    mongoose@^7.0.3 \
    @clickhouse/client@^1.4.0 \
    pg@^8.7.3 \
    pg-copy-streams@^6.0.6 \
    pg-cursor@^2.8.0 \
    pg-query-stream@^4.5.5 \
    mysql2@^2.3.3 \
    
    # Caching & Queue
    bullmq@^3.10.3 \
    cache-manager@^5.4.0 \
    cache-manager-ioredis-yet@^1.2.2 \
    cache-manager-redis-store@^3.0.1 \
    cache-manager-redis-yet@^4.1.2 \
    redis@^4.6.7 \
    redlock@^5.0.0-beta.2 \
    
    # Authentication & Security
    passport@^0.5.3 \
    passport-headerapikey@^1.2.2 \
    passport-jwt@^4.0.0 \
    passport-local@^1.0.0 \
    bcrypt@^5.0.1 \
    bcryptjs@^2.4.3 \
    
    # Email & Communication
    @sendgrid/eventwebhook@^8.0.0 \
    @sendgrid/mail@^7.7.0 \
    mailgun.js@^8.2.1 \
    nodemailer@^6.5.0 \
    twilio@^3.84.0 \
    
    # Monitoring & Logging
    @sentry/cli@^2.21.2 \
    @sentry/node@^7.73.0 \
    @sentry/profiling-node@^1.2.1 \
    @sentry/tracing@^7.102.1 \
    winston@^3.8.1 \
    winston-papertrail@^1.0.5 \
    winston-syslog@^2.6.0 \
    morgan@1.10.0 \
    nest-morgan-logger@1.0.2 \
    nest-raven@^10.0.0 \
    nest-winston@^1.6.2 \
    
    # Utilities & Helpers
    class-transformer@^0.5.1 \
    class-validator@^0.13.2 \
    class-sanitizer@^1.0.1 \
    lodash@^4.17.21 \
    date-fns@^2.30.0 \
    rxjs@^7.2.0 \
    reflect-metadata@^0.1.13 \
    
    # File Processing
    csv-parse@^5.3.5 \
    fast-csv@^4.3.6 \
    multer@^1.4.5-lts.1 \
    
    # External Services
    @slack/oauth@^2.5.4 \
    @slack/web-api@^6.7.2 \
    firebase-admin@^11.6.0 \
    stripe@^15.7.0 \
    aws-sdk@^2.1354.0 \
    posthog-node@^2.5.4 \
    
    # Additional Dependencies
    @dagrejs/graphlib@^2.1.13 \
    @js-temporal/polyfill@^0.4.4 \
    amqplib@^0.10.4 \
    form-data@^4.0.0 \
    kafkajs@^2.2.4 \
    klona@2.0.6 \
    liquidjs@^9.42.0 \
    resend@^2.1.0 \
    socket.io-client@^4.6.1 \
    svix@^1.15.0 \
    sync-fetch@^0.4.2 \
    traverse@0.6.7 \
    undici@^5.21.0

# Create TypeORM config
COPY --chown=appuser:appuser --from=backend /app/packages/server/dist ./dist/
COPY --chown=appuser:appuser --from=backend /app/packages/server/node_modules ./node_modules/
COPY --chown=appuser:appuser --from=backend /app/packages/server/src/data-source.ts ./packages/server/src/
COPY --chown=appuser:appuser scripts ./scripts/
COPY --chown=appuser:appuser packages/server/migrations/* ./migrations/

# Copy frontend build
COPY --chown=appuser:appuser --from=frontend /app/packages/client/build ./client/
COPY --chown=appuser:appuser --from=frontend /app/SENTRY_RELEASE ./SENTRY_RELEASE

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
    @types/node@18.18.0 \
    class-transformer@0.5.1 \
    class-validator@0.14.0 \
    @laudspeaker/clickhouse-migrations@1.0.1 \
    clickhouse-migrations@latest

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT:-3000}/health || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
