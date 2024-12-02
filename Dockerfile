FROM node:16 as frontend_build
ARG EXTERNAL_URL
ARG FRONTEND_SENTRY_AUTH_TOKEN
ARG FRONTEND_SENTRY_ORG=laudspeaker-rb
ARG FRONTEND_SENTRY_PROJECT=javascript-react
ARG FRONTEND_SENTRY_DSN_URL=https://2444369e8e13b39377ba90663ae552d1@o4506038702964736.ingest.sentry.io/4506038705192960
ARG REACT_APP_POSTHOG_HOST
ARG REACT_APP_POSTHOG_KEY
ARG REACT_APP_ONBOARDING_API_KEY

# Set environment variables
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

WORKDIR /app

# Copy package files first
COPY package.json package-lock.json ./
COPY packages/client/package.json ./packages/client/

# Install dependencies with specific versioning
RUN npm install -g npm@8.19.2 && \
    npm install -g cross-env env-cmd && \
    npm cache clean --force && \
    npm install --legacy-peer-deps --no-audit

# Install specific React dependencies
RUN cd packages/client && \
    npm install --save-dev @babel/plugin-proposal-private-property-in-object@^7.21.11 && \
    npm install --save-dev @babel/core@^7.22.20 && \
    npm install --save-dev @babel/preset-react@^7.22.15 && \
    npm install --save-dev babel-loader@^9.1.3

# Copy the rest of the application
COPY . .

# Update browserslist database
RUN npx update-browserslist-db@latest

# Create production environment file
RUN cd packages/client && \
    echo "REACT_APP_API_URL=${EXTERNAL_URL}" > .env.prod && \
    echo "REACT_APP_WS_BASE_URL=${EXTERNAL_URL}" >> .env.prod && \
    echo "REACT_APP_POSTHOG_HOST=${REACT_APP_POSTHOG_HOST}" >> .env.prod && \
    echo "REACT_APP_POSTHOG_KEY=${REACT_APP_POSTHOG_KEY}" >> .env.prod && \
    echo "REACT_APP_ONBOARDING_API_KEY=${REACT_APP_ONBOARDING_API_KEY}" >> .env.prod

# Build with specific flags
RUN cd packages/client && \
    INLINE_RUNTIME_CHUNK=false \
    GENERATE_SOURCEMAP=false \
    NODE_OPTIONS="--max-old-space-size=4096" \
    CI=false \
    npm run build:prod

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
COPY ./packages/server/package.json /app/

# First modify package.json to update all NestJS dependencies
RUN sed -i 's/"@nestjs\/common": "[^"]*"/"@nestjs\/common": "^10.0.0"/g' package.json && \
    sed -i 's/"@nestjs\/core": "[^"]*"/"@nestjs\/core": "^10.0.0"/g' package.json && \
    sed -i 's/"@nestjs\/websockets": "[^"]*"/"@nestjs\/websockets": "^10.0.0"/g' package.json && \
    sed -i 's/"@nestjs\/platform-socket.io": "[^"]*"/"@nestjs\/platform-socket.io": "^10.0.0"/g' package.json && \
    sed -i 's/"@nestjs\/platform-express": "[^"]*"/"@nestjs\/platform-express": "^10.0.0"/g' package.json && \
    sed -i 's/"@nestjs\/bullmq": "[^"]*"/"@nestjs\/bullmq": "^10.0.0"/g' package.json && \
    sed -i 's/"@nestjs\/cache-manager": "[^"]*"/"@nestjs\/cache-manager": "^10.0.0"/g' package.json && \
    sed -i 's/"@nestjs\/graphql": "[^"]*"/"@nestjs\/graphql": "^10.0.0"/g' package.json && \
    sed -i 's/"@liaoliaots\/nestjs-redis": "[^"]*"/"@liaoliaots\/nestjs-redis": "^10.0.0"/g' package.json

# Install dependencies
RUN npm config set fetch-retry-maxtimeout="600000" && \
    npm config set fetch-retry-mintimeout="10000" && \
    npm config set fetch-retries="5" && \
    npm cache clean --force && \
    npm install --legacy-peer-deps --no-audit --no-optional --network-timeout=600000 && \
    npm install --save-dev @types/express @types/multer && \
    npm install -g cross-env

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
