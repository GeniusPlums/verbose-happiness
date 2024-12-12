#!/bin/bash

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Check required environment variables
log "Checking required environment variables..."
: "${CLICKHOUSE_HOST:=ckai3ao0ad.ap-south-1.aws.clickhouse.cloud}"
: "${CLICKHOUSE_PORT:=8443}"
: "${CLICKHOUSE_USER:=default}"
: "${CLICKHOUSE_DB:=default}"
: "${CLICKHOUSE_PASSWORD:=fFc.5FoDUOZZQ}"

# Test base ClickHouse connection first
log "Testing ClickHouse connection..."
if ! curl --max-time 10 --user "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" \
    --data-binary 'SELECT 1' \
    "https://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}" > /dev/null 2>&1; then
    log "Error: Cannot connect to ClickHouse server"
    exit 1
fi
log "ClickHouse connection successful"

log "Using existing database: ${CLICKHOUSE_DB}"

# Run ClickHouse migrations
log "Running ClickHouse migrations..."
MAX_RETRIES=3
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if clickhouse-migrations migrate \
        --host "$CLICKHOUSE_HOST" \
        --port "$CLICKHOUSE_PORT" \
        --user "$CLICKHOUSE_USER" \
        --password "$CLICKHOUSE_PASSWORD" \
        --db "$CLICKHOUSE_DB" \
        --migrations-home ./migrations; then
        log "ClickHouse migrations completed successfully"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            log "Migration attempt $RETRY_COUNT failed, retrying in 5 seconds..."
            sleep 5
        else
            log "Warning: ClickHouse migrations failed after $MAX_RETRIES attempts. Continuing..."
            break
        fi
    fi
done

# Run TypeORM migrations
log "Running TypeORM migrations..."
if ! NODE_OPTIONS="" npx typeorm migration:run -d /app/typeorm.config.cjs; then
    log "Error: TypeORM migrations failed"
    exit 1
fi

# Process type handling
log "Setting up process type..."
case "$1" in
    'web'|'')
        export LAUDSPEAKER_PROCESS_TYPE=WEB
        if [ -f ./scripts/setup_config.sh ]; then
            bash ./scripts/setup_config.sh
        else
            log "Warning: setup_config.sh not found"
        fi
        ;;
    'queue')
        export LAUDSPEAKER_PROCESS_TYPE=QUEUE
        unset SERVE_CLIENT_FROM_NEST
        ;;
    'cron')
        export LAUDSPEAKER_PROCESS_TYPE=CRON
        unset SERVE_CLIENT_FROM_NEST
        ;;
    *)
        log "Error: Invalid process type '$1'"
        exit 1
        ;;
esac

log "Starting LaudSpeaker Process: $LAUDSPEAKER_PROCESS_TYPE"

# Start the application
exec node dist/src/main.js
