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
npm install
typeorm migration:run -d packages/server/src/data-source.ts

# Print current directory and search for data-source.ts
echo "Current directory: $(pwd)"
echo "Searching for data-source.ts files:"
find . -name "data-source.ts" -type f

# Try to run migrations with the found path
DATA_SOURCE_PATH=$(find ./packages/server -name "data-source.ts" -type f | head -n 1)
if [ -n "$DATA_SOURCE_PATH" ]; then
    echo "Found data source at: $DATA_SOURCE_PATH"
    typeorm migration:run -d "$DATA_SOURCE_PATH"
else
    echo "Error: Could not find data-source.ts"
    ls -R
    exit 1
fi

# Web server runs first. All other process types are dependant on the web server container
if [[ "$1" = 'web' || -z "$1" ]]; then
	export LAUDSPEAKER_PROCESS_TYPE=WEB

	echo "Running setup_config.sh"
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
