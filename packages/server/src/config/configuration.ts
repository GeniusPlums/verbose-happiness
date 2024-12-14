import { registerAs } from '@nestjs/config';

export const mongodbConfig = registerAs('mongodb', () => ({
  uri: process.env.MONGODB_URI,
  ssl: process.env.MONGODB_SSL === 'true',
  tls: process.env.MONGODB_TLS === 'true',
  tlsInsecure: process.env.MONGODB_TLS_INSECURE === 'true',
  directConnection: process.env.MONGODB_DIRECT_CONNECTION === 'true',
  allowInvalidCerts: process.env.MONGODB_ALLOW_INVALID_CERTS === 'true',
  allowInvalidHostnames: process.env.MONGODB_ALLOW_INVALID_HOSTNAMES === 'true',
  retryAttempts: Number(process.env.MONGODB_RETRY_ATTEMPTS) || 3,
  connectTimeoutMS: Number(process.env.MONGODB_CONNECT_TIMEOUT_MS) || 10000,
  socketTimeoutMS: Number(process.env.MONGODB_SOCKET_TIMEOUT_MS) || 45000,
  tlsProtocol: process.env.MONGODB_TLS_PROTOCOL || 'TLS_method',
  tlsMinVersion: process.env.MONGODB_TLS_MIN_VERSION || 'TLSv1.2',
  tlsMaxVersion: process.env.MONGODB_TLS_MAX_VERSION || 'TLSv1.3',
  rejectUnauthorized: process.env.MONGODB_REJECT_UNAUTHORIZED === 'true',
  host: process.env.MONGODB_HOST,
  ciphers: process.env.MONGODB_CIPHERS
}));

export const redisConfig = registerAs('redis', () => ({
  url: process.env.REDIS_URL,
  ttl: Number(process.env.REDIS_CACHE_TTL) || 5000,
  tls: process.env.NODE_ENV === 'production'
}));