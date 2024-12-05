#!/bin/bash
set -e

export SENTRY_RELEASE=$(cat SENTRY_RELEASE)

echo "Running clickhouse-migrations"
clickhouse-migrations migrate \
    --host "https://ckai3ao0ad.ap-south-1.aws.clickhouse.cloud:8443" \
    --user default \
    --password "~MG~gu62c6lFW" \
    --db ${CLICKHOUSE_DB:-default} \
    --migrations-home ./migrations

echo "Running Typeorm migrations"
npm install -g ts-node typescript @types/node typeorm
npm install --legacy-peer-deps

# Debug: Show directory structure
echo "Current directory: $(pwd)"
echo "Checking packages/server/src directory:"
ls -la packages/server/src || echo "Directory not found"
echo "Listing contents of /app/packages/server/src:"
ls -la /app/packages/server/src || echo "Directory not found"

# Run migrations with new config
typeorm migration:run -d /app/typeorm.config.js

# Process type handling
if [[ "$1" = 'web' || -z "$1" ]]; then
    export LAUDSPEAKER_PROCESS_TYPE=WEB
    bash ./scripts/setup_config.sh
fi

if [[ "$1" = 'queue' ]]; then
    export LAUDSPEAKER_PROCESS_TYPE=QUEUE
    unset SERVE_CLIENT_FROM_NEST
fi

if [[ "$1" = 'cron' ]]; then
    export LAUDSPEAKER_PROCESS_TYPE=CRON
    unset SERVE_CLIENT_FROM_NEST
fi

echo "Starting LaudSpeaker Process: $LAUDSPEAKER_PROCESS_TYPE"
node dist/src/main.js