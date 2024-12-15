# To build: docker build -f Dockerfile -t laudspeaker/laudspeaker:latest .
# To run: docker run -it -p 80:80 --env-file packages/server/.env --rm laudspeaker/laudspeaker:latest

# Base stage for shared dependencies
FROM node:18-slim AS base
WORKDIR /app
COPY package*.json ./
COPY packages/client/package*.json ./packages/client/
COPY packages/server/package*.json ./packages/server/

# Install SSL certificates and other necessary packages
RUN apt-get update && \
    apt-get install -y \
    ca-certificates \
    openssl \
    wget \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Set Node to use system CA certificates and handle self-signed certificates
ENV NODE_OPTIONS="--use-openssl-ca"
ENV NODE_TLS_REJECT_UNAUTHORIZED="0"
ENV PGSSLMODE="require"

# Debug: Check if package.json exists in base
RUN ls -la /app/package.json || echo "No package.json in base"

# Frontend build stage
FROM node:18-slim AS frontend
WORKDIR /app

# Copy base files
COPY --from=base /app ./

# Install dependencies first (this helps with caching)
COPY package*.json ./
COPY packages/client/package*.json ./packages/client/

# Update npm and install dependencies
RUN npm install -g npm@10.9.2 && \
    cd packages/client && \
    npm install && \
    npm install --save-dev @babel/plugin-proposal-private-property-in-object @types/react-helmet && \
    npm install --save react-helmet @nestjs/axios@3.1.3

# Copy client source
COPY packages/client ./packages/client

# Create TypeScript declaration file
RUN cd packages/client && \
    echo "declare module 'react-helmet';" > react-helmet.d.ts

# Set environment variables and build
RUN cd packages/client && \
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

# Copy base files
COPY --from=base /app ./

# Install dependencies first (this helps with caching)
COPY package*.json ./
COPY packages/server/package*.json ./packages/server/

# Update npm and install dependencies
RUN npm install -g npm@10.9.2 && \
    cd packages/server && \
    npm install && \
    npm install @nestjs/axios@3.1.3

# Copy server source
COPY packages/server ./packages/server

# Build with environment variables
RUN cd packages/server && \
    NODE_ENV=production \
    npm run build

# Final stage
FROM node:18-slim
WORKDIR /app

# Install necessary packages including SSL support
RUN apt-get update && \
    apt-get install -y \
    curl \
    ca-certificates \
    openssl \
    && rm -rf /var/lib/apt/lists/* && \
    adduser --uid 1001 --disabled-password --gecos "" appuser && \
    mkdir -p \
        /app/packages/server/src \
        /app/migrations \
        /app/client \
        /app/node_modules \
        /home/appuser/.npm-global && \
    chown -R appuser:appuser /app /home/appuser && \
    chmod -R 755 /app

# Create TypeORM config file
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
    rejectUnauthorized: false,\n\
    sslmode: 'require',\n\
    ssl: true\n\
  } : false\n\
});\n\
\n\
module.exports = dataSource;\n\
module.exports.default = dataSource;" > /app/typeorm.config.cjs && \
    chown appuser:appuser /app/typeorm.config.cjs && \
    chmod 644 /app/typeorm.config.cjs

# Copy files and configs first
COPY --chown=appuser:appuser docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

# Install all dependencies from package.json
COPY --chown=appuser:appuser package*.json ./
RUN npm install --legacy-peer-deps \
    @babel/core@^7.16.0 \
    @golevelup/ts-jest@^0.3.7 \
    @svgr/webpack@^5.5.0 \
    case-sensitive-paths-webpack-plugin@^2.4.0 \
    env-cmd@^10.1.0 \
    foreman@^3.0.1 \
    @tailwindcss/forms@^0.5.3 \
    @tisoap/react-flow-smart-edge@^3.0.0 \
    @wojtekmaj/react-daterange-picker@^3.4.0 \
    ace-builds@^1.15.0 \
    d3-hierarchy@^3.1.2 \
    framer-motion@^10.16.4 \
    keyboardjs@^2.7.0 \
    react-ace@^10.1.0 \
    react-confirm-alert@^3.0.6 \
    react-custom-scrollbars-2@^4.5.0 \
    react-draggable@^4.4.5 \
    react-google-recaptcha@^2.1.0 \
    react-joyride@^2.5.4 \
    react-lines-ellipsis@^0.15.3 \
    react-loader-spinner@^5.3.4 \
    react-markdown@^8.0.6 \
    react-password-checklist@^1.5.0 \
    react-popper@^2.3.0 \
    react-querybuilder@^6.4.1 \
    react-slider@^2.0.4 \
    react-social-media-embed@^2.3.4 \
    react-tagsinput@^3.20.3 \
    react-use@^17.4.0 \
    recharts@^2.12.2 \
    victory@^36.6.3 \
    @liaoliaots/nestjs-redis@^9.0.5 \
    async-dash@^1.0.4 \
    camelcase@^6.2.1 \
    dayjs@^1.11.10 \
    luxon@^3.2.1 \
    moment-timezone@^0.5.43 \
    papaparse@^5.4.1 \
    posthog-js@^1.29.3 \
    taskforce-connector@^1.24.3 \
    uuid@^8.3.2 \
    uuidv4@^6.2.13 \
    @types/bcryptjs@^2.4.2 \
    @types/d3-hierarchy@^3.1.2 \
    @types/papaparse@^5.3.7 \
    @types/react-color@^3.0.6 \
    @types/validator@^13.11.7 \
    tst-reflect@0.7.4 \
    tst-reflect-transformer@0.12.1 \
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
    @nestjs/axios@^3.1.3 \
    @nestjs/bullmq@^1.1.0 \
    @nestjs/cache-manager@^2.2.0 \
    @nestjs/mapped-types@^1.2.2 \
    typeorm@^0.3.12 \
    mongoose@^7.0.3 \
    @clickhouse/client@^1.4.0 \
    pg@^8.7.3 \
    pg-copy-streams@^6.0.6 \
    pg-cursor@^2.8.0 \
    pg-query-stream@^4.5.5 \
    mysql2@^2.3.3 \
    bullmq@^3.10.3 \
    cache-manager@^5.4.0 \
    cache-manager-ioredis-yet@^1.2.2 \
    cache-manager-redis-store@^3.0.1 \
    cache-manager-redis-yet@^4.1.2 \
    redis@^4.6.7 \
    redlock@^5.0.0-beta.2 \
    passport@^0.5.3 \
    passport-headerapikey@^1.2.2 \
    passport-jwt@^4.0.0 \
    passport-local@^1.0.0 \
    bcrypt@^5.0.1 \
    bcryptjs@^2.4.3 \
    @sendgrid/eventwebhook@^8.0.0 \
    @sendgrid/mail@^7.7.0 \
    mailgun.js@^8.2.1 \
    nodemailer@^6.5.0 \
    twilio@^3.84.0 \
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
    class-transformer@^0.5.1 \
    class-validator@^0.13.2 \
    class-sanitizer@^1.0.1 \
    lodash@^4.17.21 \
    date-fns@^2.30.0 \
    rxjs@^7.2.0 \
    reflect-metadata@^0.1.13 \
    csv-parse@^5.3.5 \
    fast-csv@^4.3.6 \
    multer@^1.4.5-lts.1 \
    @slack/oauth@^2.5.4 \
    @slack/web-api@^6.7.2 \
    firebase-admin@^11.6.0 \
    stripe@^15.7.0 \
    aws-sdk@^2.1354.0 \
    posthog-node@^2.5.4 \
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
    undici@^5.21.0 \
    @emotion/react@11.9.3 \
    @emotion/styled@11.9.3 \
    @good-ghosting/random-name-generator@^1.0.3 \
    @headlessui/react@^1.7.3 \
    @heroicons/react@^2.0.12 \
    @lottiefiles/react-lottie-player@^3.5.3 \
    @material-tailwind/react@^1.2.4 \
    @mui/icons-material@^5.8.4 \
    @mui/lab@^5.0.0-alpha.89 \
    @mui/material@5.11.0 \
    @pmmmwh/react-refresh-webpack-plugin@^0.5.3 \
    @react-oauth/google@^0.2.6 \
    @reduxjs/toolkit@^1.9.5 \
    @sentry/react@^7.73.0 \
    antd@^5.14.2 \
    grapesjs@^0.19.5 \
    react@^18.2.0 \
    react-dom@18.2.0 \
    react-router-dom@6.3.0 \
    reactflow@^11.5.6 \
    redux@4.2.0 \
    @4tw/cypress-drag-drop@^2.2.1 \
    @nestjs/schematics@^9.0.0 \
    @types/cron@^2.0.0 \
    @types/express@^4.17.13 \
    @types/jest@27.5.2 \
    @types/lodash@^4.14.184 \
    @typescript-eslint/eslint-plugin@^5.39.0 \
    @typescript-eslint/parser@^5.39.0 \
    cypress@12.9.0 \
    dotenv@16.0.3 \
    eslint@^8.24.0 \
    prettier@^2.7.1 \
    @databricks/sql@1.0.0 \
    @sendgrid/client@^7.7.0 \
    rimraf@^3.0.2

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

ENV PORT=3000 \
    NODE_ENV=production \
    FORCE_HTTPS=false \
    LAUDSPEAKER_PROCESS_TYPE=WEB \
    PATH="/home/appuser/.npm-global/bin:$PATH" \
    NPM_CONFIG_PREFIX=/home/appuser/.npm-global \
    TYPEORM_CONFIG=/app/typeorm.config.cjs \
    TS_NODE_PROJECT=tsconfig.json \
    JWT_KEY=h1E8OZF6TcLfofpWjQxS5sNRgRb9Mgc33dtYtBr1mAkqn7vXiIU4PKy2CDVz0GeY

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
