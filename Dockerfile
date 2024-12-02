# To build: docker build -f Dockerfile -t laudspeaker/laudspeaker:latest .
# To run: docker run -it -p 80:80 --env-file packages/server/.env --rm laudspeaker/laudspeaker:latest

FROM node:16 as base
WORKDIR /app
COPY package*.json ./
COPY packages/client/package*.json ./packages/client/
COPY packages/server/package*.json ./packages/server/

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
COPY --from=base /app ./
COPY packages/server ./packages/server

# Create type declarations
RUN mkdir -p /app/packages/server/src/@types && \
    echo 'import { User } from "../entities/user.entity";' > /app/packages/server/src/@types/express.d.ts && \
    echo 'declare global {' >> /app/packages/server/src/@types/express.d.ts && \
    echo '  namespace Express {' >> /app/packages/server/src/@types/express.d.ts && \
    echo '    interface Request {' >> /app/packages/server/src/@types/express.d.ts && \
    echo '      user?: User;' >> /app/packages/server/src/@types/express.d.ts && \
    echo '    }' >> /app/packages/server/src/@types/express.d.ts && \
    echo '    interface User extends User {}' >> /app/packages/server/src/@types/express.d.ts && \
    echo '    namespace Multer {' >> /app/packages/server/src/@types/express.d.ts && \
    echo '      interface File {' >> /app/packages/server/src/@types/express.d.ts && \
    echo '        fieldname: string;' >> /app/packages/server/src/@types/express.d.ts && \
    echo '        originalname: string;' >> /app/packages/server/src/@types/express.d.ts && \
    echo '        encoding: string;' >> /app/packages/server/src/@types/express.d.ts && \
    echo '        mimetype: string;' >> /app/packages/server/src/@types/express.d.ts && \
    echo '        size: number;' >> /app/packages/server/src/@types/express.d.ts && \
    echo '        destination: string;' >> /app/packages/server/src/@types/express.d.ts && \
    echo '        filename: string;' >> /app/packages/server/src/@types/express.d.ts && \
    echo '        path: string;' >> /app/packages/server/src/@types/express.d.ts && \
    echo '        buffer: Buffer;' >> /app/packages/server/src/@types/express.d.ts && \
    echo '      }' >> /app/packages/server/src/@types/express.d.ts && \
    echo '    }' >> /app/packages/server/src/@types/express.d.ts && \
    echo '  }' >> /app/packages/server/src/@types/express.d.ts && \
    echo '}' >> /app/packages/server/src/@types/express.d.ts

# Remove existing dependencies from package.json to avoid conflicts
RUN cd packages/server && \
    sed -i '/"dependencies"/,/}/{ /"@nestjs\/common"/d; /"@nestjs\/core"/d; /"@nestjs\/websockets"/d; /"@nestjs\/platform-socket.io"/d; /"@nestjs\/platform-express"/d; /"@nestjs\/bullmq"/d; /"@nestjs\/cache-manager"/d; /"@nestjs\/graphql"/d; /"@liaoliaots\/nestjs-redis"/d; }' package.json

# Install dependencies in correct order with force resolution for cache-manager
RUN cd packages/server && \
    npm install -g npm@8.19.2 && \
    npm install -g cross-env && \
    npm install --save \
        @nestjs/common@9.4.3 \
        @nestjs/core@9.4.3 \
        @nestjs/websockets@9.4.3 \
        @nestjs/platform-socket.io@9.4.3 \
        @nestjs/platform-express@9.4.3 \
        @nestjs/bullmq@9.4.3 \
        @nestjs/graphql@9.4.3 \
        cache-manager@4.1.0 \
        @nestjs/cache-manager@1.0.0 && \
    npm install --save @liaoliaots/nestjs-redis@9.0.5 && \
    npm install --save-dev @types/express @types/multer && \
    npm install --force

# Build backend
RUN cd packages/server && npm run build

# Handle backend source maps
RUN cd packages/server && \
    if [ -z "$BACKEND_SENTRY_AUTH_TOKEN" ] ; then \
        echo "Not building sourcemaps, BACKEND_SENTRY_AUTH_TOKEN not provided" ; \
    else \
        npm run build:server:sourcemaps ; \
    fi

# Generate release version
RUN echo "$(date +%Y-%m-%d_%H-%M-%S)" > /app/SENTRY_RELEASE

FROM node:16 as final
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

# Copy files from build stages
COPY packages/server/package.json ./
COPY --from=frontend_build /app/packages/client/build ./client
COPY --from=backend_build /app/packages/server/dist ./dist
COPY --from=backend_build /app/packages/server/node_modules ./node_modules
COPY --from=backend_build /app/SENTRY_RELEASE ./
COPY scripts ./scripts

# Expose port and setup entrypoint
EXPOSE 80
COPY docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh
ENTRYPOINT ["./docker-entrypoint.sh"]
