# To build: docker build -f Dockerfile -t laudspeaker/laudspeaker:latest .
# To run: docker run -it -p 80:80 --env-file packages/server/.env --rm laudspeaker/laudspeaker:latest

# Base stage for shared dependencies
FROM node:18-slim AS base
WORKDIR /app
COPY package*.json ./
COPY packages/client/package*.json ./packages/client/
COPY packages/server/package*.json ./packages/server/

FROM node:18-slim as frontend_build
ARG EXTERNAL_URL
ARG FRONTEND_SENTRY_AUTH_TOKEN
ARG FRONTEND_SENTRY_ORG=laudspeaker-rb
ARG FRONTEND_SENTRY_PROJECT=javascript-react
ARG FRONTEND_SENTRY_DSN_URL=https://2444369e8e13b39377ba90663ae552d1@o4506038702964736.ingest.sentry.io/4506038705192960
ARG REACT_APP_POSTHOG_HOST
ARG REACT_APP_POSTHOG_KEY
ARG REACT_APP_ONBOARDING_API_KEY

ENV SENTRY_AUTH_TOKEN=${FRONTEND_SENTRY_AUTH_TOKEN} \
    SENTRY_ORG=${FRONTEND_SENTRY_ORG} \
    SENTRY_PROJECT=${FRONTEND_SENTRY_PROJECT} \
    REACT_APP_SENTRY_DSN_URL_FRONTEND=${FRONTEND_SENTRY_DSN_URL} \
    REACT_APP_WS_BASE_URL=${EXTERNAL_URL} \
    REACT_APP_POSTHOG_HOST=${REACT_APP_POSTHOG_HOST} \
    REACT_APP_POSTHOG_KEY=${REACT_APP_POSTHOG_KEY} \
    REACT_APP_ONBOARDING_API_KEY=${REACT_APP_ONBOARDING_API_KEY} \
    NODE_OPTIONS="--max-old-space-size=4096"

WORKDIR /app
COPY --from=base /app ./
COPY packages/client ./packages/client

RUN cd packages/client && \
    npm ci --legacy-peer-deps && \
    npm install --save-dev @babel/plugin-proposal-private-property-in-object @types/react-helmet && \
    npm install --save react-helmet && \
    echo "declare module 'react-helmet';" > react-helmet.d.ts && \
    npm run format:client && \
    npm run build:client

# Handle frontend source maps conditionally
RUN if [ -z "$FRONTEND_SENTRY_AUTH_TOKEN" ] ; then \
        echo "Not building sourcemaps, FRONTEND_SENTRY_AUTH_TOKEN not provided" ; \
    else \
        REACT_APP_SENTRY_RELEASE=$(./node_modules/.bin/sentry-cli releases propose-version) npm run build:client:sourcemaps ; \
    fi

FROM node:18-slim as backend_build
ARG BACKEND_SENTRY_AUTH_TOKEN
ARG BACKEND_SENTRY_ORG=laudspeaker-rb
ARG BACKEND_SENTRY_PROJECT=node

ENV SENTRY_AUTH_TOKEN=${BACKEND_SENTRY_AUTH_TOKEN} \
    SENTRY_ORG=${BACKEND_SENTRY_ORG} \
    SENTRY_PROJECT=${BACKEND_SENTRY_PROJECT}

WORKDIR /app
COPY --from=base /app ./
COPY . /app

# Install additional dependencies
RUN npm install --legacy-peer-deps \
    @good-ghosting/random-name-generator@2.0.0 \
    @js-temporal/polyfill@0.4.4 \
    @dagrejs/graphlib@2.1.13 \
    fast-csv@4.3.6 \
    aws-sdk@2.1502.0 \
    undici@5.0.0

RUN npm run build:server

# Handle backend source maps conditionally
RUN if [ -z "$BACKEND_SENTRY_AUTH_TOKEN" ] ; then \
        echo "Not building sourcemaps, BACKEND_SENTRY_AUTH_TOKEN not provided" ; \
    else \
        npm run build:server:sourcemaps ; \
    fi

RUN ./node_modules/.bin/sentry-cli releases propose-version > /app/SENTRY_RELEASE

FROM node:18-slim As final
# Create non-root user
RUN adduser --uid 1001 --disabled-password --gecos "" appuser && \
    mkdir -p /app/client /app/dist /app/node_modules && \
    chown -R appuser:appuser /app

# Env vars
ARG BACKEND_SENTRY_DSN_URL=https://15c7f142467b67973258e7cfaf814500@o4506038702964736.ingest.sentry.io/4506040630640640
ENV SENTRY_DSN_URL_BACKEND=${BACKEND_SENTRY_DSN_URL} \
    NODE_ENV=production \
    ENVIRONMENT=production \
    SERVE_CLIENT_FROM_NEST=true \
    CLIENT_PATH=/app/client \
    PATH=/app/node_modules/.bin:$PATH \
    FRONTEND_URL=${EXTERNAL_URL} \
    POSTHOG_HOST=https://app.posthog.com \
    POSTHOG_KEY=RxdBl8vjdTwic7xTzoKTdbmeSC1PCzV6sw-x-FKSB-k

# Setting working directory
WORKDIR /app

USER appuser

# Copy files with proper ownership
COPY --chown=appuser:appuser ./packages/server/package.json /app/
COPY --chown=appuser:appuser --from=frontend_build /app/packages/client/build /app/client
COPY --chown=appuser:appuser --from=backend_build /app/packages/server/dist /app/dist
COPY --chown=appuser:appuser --from=backend_build /app/node_modules /app/node_modules
COPY --chown=appuser:appuser --from=backend_build /app/packages /app/packages
COPY --chown=appuser:appuser --from=backend_build /app/SENTRY_RELEASE /app/
COPY --chown=appuser:appuser ./scripts /app/scripts/

# Copy and set up entrypoint
COPY --chown=appuser:appuser docker-entrypoint.sh /app/
RUN chmod +x /app/docker-entrypoint.sh

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT:-3000}/health || exit 1

ENTRYPOINT ["/app/docker-entrypoint.sh"]
