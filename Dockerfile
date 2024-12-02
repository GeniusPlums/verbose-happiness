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
WORKDIR /app
COPY ./packages/client/package.json /app/
COPY ./package-lock.json /app/

# Fixed npm config and install commands with additional dependency
RUN npm config set fetch-retry-maxtimeout="600000" && \
    npm config set fetch-retry-mintimeout="10000" && \
    npm config set fetch-retries="5" && \
    npm install --legacy-peer-deps --network-timeout=600000 && \
    npm install @sentry/cli --legacy-peer-deps && \
    npm install -g cross-env && \
    npm install --save-dev @babel/plugin-proposal-private-property-in-object

COPY . /app
RUN npm run format:client

# Split the build command to use production mode and increase memory limit
RUN NODE_ENV=production npm run build:client

# Basically an if else but more readable in two lines
RUN if [ -z "$FRONTEND_SENTRY_AUTH_TOKEN" ] ; then echo "Not building sourcemaps, FRONTEND_SENTRY_AUTH_TOKEN not provided" ; fi
# Need to add sentry_release here because of: https://stackoverflow.com/a/41864647
RUN if [ ! -z "$FRONTEND_SENTRY_AUTH_TOKEN" ] ; then REACT_APP_SENTRY_RELEASE=$(./node_modules/.bin/sentry-cli releases propose-version) npm run build:client:sourcemaps ; fi

FROM node:16 as backend_build
ARG BACKEND_SENTRY_AUTH_TOKEN
ARG BACKEND_SENTRY_ORG=laudspeaker-rb
ARG BACKEND_SENTRY_PROJECT=node
ENV SENTRY_AUTH_TOKEN=${BACKEND_SENTRY_AUTH_TOKEN}
ENV SENTRY_ORG=${BACKEND_SENTRY_ORG}
ENV SENTRY_PROJECT=${BACKEND_SENTRY_PROJECT}
ENV NODE_OPTIONS="--max-old-space-size=8192"
WORKDIR /app
COPY --from=frontend_build /app/packages/client/package.json /app/
COPY ./packages/server/package.json /app

# Fixed npm config and install commands for backend
RUN npm config set fetch-retry-maxtimeout="600000" && \
    npm config set fetch-retry-mintimeout="10000" && \
    npm config set fetch-retries="5" && \
    npm install --legacy-peer-deps --network-timeout=600000 && \
    npm install @sentry/cli --legacy-peer-deps && \
    npm install -g cross-env

COPY . /app
RUN npm run build:server
# Basically an if else but more readable in two lines
RUN if [ -z "$BACKEND_SENTRY_AUTH_TOKEN" ] ; then echo "Not building sourcemaps, BACKEND_SENTRY_AUTH_TOKEN not provided" ; fi
RUN if [ ! -z "$BACKEND_SENTRY_AUTH_TOKEN" ] ; then npm run build:server:sourcemaps ; fi

# Replace problematic sentry-cli command with a fallback version string
RUN echo "$(date +%Y-%m-%d_%H-%M-%S)" > /app/SENTRY_RELEASE

FROM node:16 As final
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
