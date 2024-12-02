# To build: docker build -f Dockerfile -t laudspeaker/laudspeaker:latest .
# To run: docker run -it -p 80:80 --env-file packages/server/.env --rm laudspeaker/laudspeaker:latest
FROM node:16 as frontend_build
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
ENV NODE_OPTIONS="--max-old-space-size=8192"
ENV NODE_ENV=production
WORKDIR /app

# Copy package files first for better caching
COPY ./packages/client/package.json /app/
COPY ./package-lock.json /app/

# Fixed npm config and install commands with optimization
RUN npm config set fetch-retry-maxtimeout="600000" && \
    npm config set fetch-retry-mintimeout="10000" && \
    npm config set fetch-retries="5" && \
    npm cache clean --force && \
    npm install --legacy-peer-deps --no-audit --no-optional --network-timeout=600000 && \
    npm install @sentry/cli --legacy-peer-deps && \
    npm install -g cross-env && \
    npm install --save-dev @babel/plugin-proposal-private-property-in-object && \
    npm install --save-dev eslint-config-airbnb-typescript @typescript-eslint/eslint-plugin @typescript-eslint/parser

# Copy source files
COPY . /app

# Format code using npx prettier directly
RUN cd packages/client && \
    npm install --save-dev prettier && \
    npx prettier --write "src/**/*.ts" "src/**/*.tsx"

# Install additional dependencies for the client package
RUN cd packages/client && \
    npm install --save-dev eslint-config-airbnb-typescript @typescript-eslint/eslint-plugin @typescript-eslint/parser

# Build frontend with optimizations
RUN npx update-browserslist-db@latest && \
    GENERATE_SOURCEMAP=false \
    NODE_OPTIONS="--max-old-space-size=8192" \
    npm run build:prod -w packages/client --production

# Handle Sentry source maps
RUN if [ -z "$FRONTEND_SENTRY_AUTH_TOKEN" ] ; then echo "Not building sourcemaps, FRONTEND_SENTRY_AUTH_TOKEN not provided" ; fi
RUN if [ ! -z "$FRONTEND_SENTRY_AUTH_TOKEN" ] ; then REACT_APP_SENTRY_RELEASE=$(./node_modules/.bin/sentry-cli releases propose-version) npm run build:client:sourcemaps ; fi

FROM node:16 as backend_build
ARG BACKEND_SENTRY_AUTH_TOKEN
ARG BACKEND_SENTRY_ORG=laudspeaker-rb
ARG BACKEND_SENTRY_PROJECT=node
ENV SENTRY_AUTH_TOKEN=${BACKEND_SENTRY_AUTH_TOKEN}
ENV SENTRY_ORG=${BACKEND_SENTRY_ORG}
ENV SENTRY_PROJECT=${BACKEND_SENTRY_PROJECT}
ENV NODE_OPTIONS="--max-old-space-size=8192"
ENV NODE_ENV=production
WORKDIR /app

# Copy package files for backend
COPY --from=frontend_build /app/packages/client/package.json /app/
COPY ./packages/server/package.json /app

# Install backend dependencies with optimization
RUN npm config set fetch-retry-maxtimeout="600000" && \
    npm config set fetch-retry-mintimeout="10000" && \
    npm config set fetch-retries="5" && \
    npm cache clean --force && \
    npm install --legacy-peer-deps --no-audit --no-optional --network-timeout=600000 && \
    npm install @sentry/cli --legacy-peer-deps && \
    npm install -g cross-env

# Copy and build backend
COPY . /app
RUN npm run build:server

# Handle backend source maps
RUN if [ -z "$BACKEND_SENTRY_AUTH_TOKEN" ] ; then echo "Not building sourcemaps, BACKEND_SENTRY_AUTH_TOKEN not provided" ; fi
RUN if [ ! -z "$BACKEND_SENTRY_AUTH_TOKEN" ] ; then npm run build:server:sourcemaps ; fi

# Generate release version
RUN echo "$(date +%Y-%m-%d_%H-%M-%S)" > /app/SENTRY_RELEASE

FROM node:16 As final
# Environment variables
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

# Setup final image
WORKDIR /app

# Copy necessary files
COPY ./packages/server/package.json /app
COPY --from=frontend_build /app/packages/client/build /app/client
COPY --from=backend_build /app/packages/server/dist /app/dist
COPY --from=backend_build /app/node_modules /app/node_modules
COPY --from=backend_build /app/packages /app/packages
COPY --from=backend_build /app/SENTRY_RELEASE /app/
COPY ./scripts /app/scripts/

# Expose port
EXPOSE 80

# Setup entrypoint
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh
ENTRYPOINT ["/app/docker-entrypoint.sh"]
