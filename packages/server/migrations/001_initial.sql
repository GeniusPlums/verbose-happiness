-- Initial ClickHouse migration
CREATE TABLE IF NOT EXISTS events (
    id UUID DEFAULT generateUUIDv4(),
    timestamp DateTime DEFAULT now(),
    event_type String,
    user_id String,
    properties String
) ENGINE = MergeTree()
ORDER BY (timestamp, id);