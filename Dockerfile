# To build: docker build -f Dockerfile -t laudspeaker/laudspeaker:latest .
# To run: docker run -it -p 80:80 --env-file packages/server/.env --rm laudspeaker/laudspeaker:latest

# Base stage
FROM node:18 as base
WORKDIR /app
COPY package*.json ./
COPY packages/client/package*.json ./packages/client/
COPY packages/server/package*.json ./packages/server/

# Frontend build stage
FROM node:18 as frontend_build
ARG EXTERNAL_URL
ARG FRONTEND_SENTRY_AUTH_TOKEN
ARG FRONTEND_SENTRY_ORG=laudspeaker-rb
ARG FRONTEND_SENTRY_PROJECT=javascript-react
ARG FRONTEND_SENTRY_DSN_URL=https://2444369e8e13b39377ba90663ae552d1@o4506038702964736.ingest.sentry.io/4506038705192960
ARG REACT_APP_POSTHOG_HOST
ARG REACT_APP_POSTHOG_KEY
ARG REACT_APP_ONBOARDING_API_KEY

ENV SENTRY_AUTH_TOKEN=${FRONTEND_SENTRY_AUTH_TOKEN}
ENV SENTRY_ORG=${FRONTEND_SENTRY_ORG}
ENV SENTRY_PROJECT=${FRONTEND_SENTRY_PROJECT}
ENV REACT_APP_SENTRY_DSN_URL_FRONTEND=${FRONTEND_SENTRY_DSN_URL}
ENV REACT_APP_WS_BASE_URL=${EXTERNAL_URL}
ENV REACT_APP_POSTHOG_HOST=${REACT_APP_POSTHOG_HOST}
ENV REACT_APP_POSTHOG_KEY=${REACT_APP_POSTHOG_KEY}
ENV REACT_APP_ONBOARDING_API_KEY=${REACT_APP_ONBOARDING_API_KEY}
ENV NODE_OPTIONS="--max-old-space-size=4096"
ENV NODE_ENV=production
ENV TS_NODE_TRANSPILE_ONLY=true

WORKDIR /app
COPY --from=base /app ./
COPY packages/client ./packages/client

# Install and build frontend
RUN cd packages/client && \
    npm install --legacy-peer-deps && \
    npm install --save-dev @babel/plugin-proposal-private-property-in-object && \
    npm install --save-dev @types/react-helmet && \
    npm install --save react-helmet && \
    echo "declare module 'react-helmet';" > react-helmet.d.ts

# Create production environment file
RUN cd packages/client && \
    echo "REACT_APP_API_URL=${EXTERNAL_URL}" > .env.prod && \
    echo "REACT_APP_WS_BASE_URL=${EXTERNAL_URL}" >> .env.prod && \
    echo "REACT_APP_POSTHOG_HOST=${REACT_APP_POSTHOG_HOST}" >> .env.prod && \
    echo "REACT_APP_POSTHOG_KEY=${REACT_APP_POSTHOG_KEY}" >> .env.prod && \
    echo "REACT_APP_ONBOARDING_API_KEY=${REACT_APP_ONBOARDING_API_KEY}" >> .env.prod

# Build frontend
RUN cd packages/client && \
    DISABLE_ESLINT_PLUGIN=true \
    EXTEND_ESLINT=false \
    ESLINT_NO_DEV_ERRORS=true \
    GENERATE_SOURCEMAP=false \
    NODE_OPTIONS="--max-old-space-size=4096" \
    TSC_COMPILE_ON_ERROR=true \
    CI=false \
    npm run build:prod

# Handle frontend source maps
RUN cd packages/client && \
    if [ -z "$FRONTEND_SENTRY_AUTH_TOKEN" ] ; then \
        echo "Not building sourcemaps, FRONTEND_SENTRY_AUTH_TOKEN not provided" ; \
    else \
        REACT_APP_SENTRY_RELEASE=$(./node_modules/.bin/sentry-cli releases propose-version) npm run build:client:sourcemaps ; \
    fi

# Backend build stage
FROM node:18 as backend_build

WORKDIR /app

# Copy from base
COPY --from=base /app ./

# Create directory structure
RUN mkdir -p /app/packages/server/src

# Copy entire server source
COPY packages/server ./packages/server

# Verification step
RUN ls -la /app/packages/server/src/data-source.ts

# Install and build
RUN cd packages/server && \
    npm install && \
    npm run build

# Debug output
RUN tree /app/packages/server/src || true

# Final stage
FROM node:18 as final
ARG BACKEND_SENTRY_DSN_URL=https://15c7f142467b67973258e7cfaf814500@o4506038702964736.ingest.sentry.io/4506040630640640
ENV SENTRY_DSN_URL_BACKEND=${BACKEND_SENTRY_DSN_URL}
ENV NODE_ENV=production
ENV ENVIRONMENT=production
ENV SERVE_CLIENT_FROM_NEST=true
ENV CLIENT_PATH=/app/client
ENV PATH /app/node_modules/.bin:$PATH
ENV FRONTEND_URL=${EXTERNAL_URL}
ENV POSTHOG_HOST=https://app.posthog.com
ENV POSTHOG_KEY=RxdBl8vjdTwic7xTzoKTdbmeSC1PCzV6sw-x-FKSB-k

WORKDIR /app

# Create directory structure first
RUN mkdir -p /app/packages/server/src /app/migrations

# Copy build artifacts
COPY --from=frontend_build /app/packages/client/build ./client
COPY --from=backend_build /app/packages/server/dist ./dist
COPY --from=backend_build /app/packages/server/node_modules ./node_modules
COPY --from=backend_build /app/SENTRY_RELEASE ./

# Copy additional files
COPY scripts ./scripts
COPY packages/server/migrations/* ./migrations/
COPY docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

# Install global dependencies
RUN npm install -g clickhouse-migrations

# Configure container
EXPOSE 80
ENTRYPOINT ["./docker-entrypoint.sh"]
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:${PORT:-3000}/health || exit 1
