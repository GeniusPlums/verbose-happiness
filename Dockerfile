# To build: docker build -f Dockerfile -t laudspeaker/laudspeaker:latest .
# To run: docker run -it -p 80:80 --env-file packages/server/.env --rm laudspeaker/laudspeaker:latest

# Base stage for shared dependencies
FROM node:16 AS base
WORKDIR /app
COPY package*.json ./
COPY packages/client/package*.json ./packages/client/
COPY packages/server/package*.json ./packages/server/

# Debug: Check if package.json exists in base stage
RUN ls -la /app/package.json || echo "No package.json in base"

# Frontend build stage
FROM node:16 AS frontend_build
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
FROM node:16 AS backend_build
ARG BACKEND_SENTRY_AUTH_TOKEN
ARG BACKEND_SENTRY_ORG=laudspeaker-rb
ARG BACKEND_SENTRY_PROJECT=node
ENV SENTRY_AUTH_TOKEN=${BACKEND_SENTRY_AUTH_TOKEN}
ENV SENTRY_ORG=${BACKEND_SENTRY_ORG}
ENV SENTRY_PROJECT=${BACKEND_SENTRY_PROJECT}
WORKDIR /app
COPY --from=frontend_build /app/packages/client/package.json /app/
COPY ./packages/server/package.json /app
RUN npm install --legacy-peer-deps --force && \
    npm install --save --legacy-peer-deps --force \
    @good-ghosting/random-name-generator@2.0.0 \
    @js-temporal/polyfill@0.4.4 \
    @nestjs/common@9.4.3 \
    @liaoliaots/nestjs-redis@9.0.5
COPY . /app
RUN npm run build:server
# Basically an if else but more readable in two lines
RUN if [ -z "$BACKEND_SENTRY_AUTH_TOKEN" ] ; then echo "Not building sourcemaps, BACKEND_SENTRY_AUTH_TOKEN not provided" ; fi
RUN if [ ! -z "$BACKEND_SENTRY_AUTH_TOKEN" ] ; then npm run build:server:sourcemaps ; fi

RUN ./node_modules/.bin/sentry-cli releases propose-version > /app/SENTRY_RELEASE

# Final stage
FROM node:16 AS final
# Env vars
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

# Setting working directory
WORKDIR /app

#Copy package.json from server over
COPY ./packages/server/package.json /app

#Copy over all app files
COPY --from=frontend_build /app/packages/client/build /app/client
COPY --from=backend_build /app/packages/server/dist /app/dist
COPY --from=backend_build /app/node_modules /app/node_modules
COPY --from=backend_build /app/packages /app/packages
COPY --from=backend_build /app/SENTRY_RELEASE /app/
COPY ./scripts /app/scripts/

#Expose web port
EXPOSE 80

COPY docker-entrypoint.sh /app/docker-entrypoint.sh

RUN ["chmod", "+x", "/app/docker-entrypoint.sh"]

ENTRYPOINT ["/app/docker-entrypoint.sh"]
