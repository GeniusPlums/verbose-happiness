import { TypeOrmOptionsFactory, TypeOrmModuleOptions } from '@nestjs/typeorm';
import * as os from 'os';

export class TypeOrmConfigService implements TypeOrmOptionsFactory {
  public createTypeOrmOptions(): TypeOrmModuleOptions {
    console.log('Database Environment Variables:');
    console.log({
      // PostgreSQL variables
      DB_HOST: process.env.DB_HOST,
      DB_PORT: process.env.DB_PORT,
      DB_NAME: process.env.DB_NAME,
      DB_USER: process.env.DB_USER,
      DB_SSL: process.env.DB_SSL,
      // MongoDB variables
      MONGODB_URI: process.env.MONGODB_URI,
      MONGODB_HOST: process.env.MONGODB_HOST,
      MONGODB_PORT: process.env.MONGODB_PORT,
      MONGODB_DATABASE: process.env.MONGODB_DATABASE,
      MONGODB_USER: process.env.MONGODB_USER,
      NODE_ENV: process.env.NODE_ENV
    });

    let totalMaxConnections = process.env.DATABASE_MAX_CONNECTIONS
      ? +process.env.DATABASE_MAX_CONNECTIONS
      : 100;
    let maxReplicas = process.env.DEPLOY_MAX_REPLICAS
      ? +process.env.DEPLOY_MAX_REPLICAS
      : 1;
    let connectionsPerReplica = Math.floor(totalMaxConnections / maxReplicas);
    let maxProcessCountPerReplica = process.env.MAX_PROCESS_COUNT_PER_REPLICA
      ? +process.env.MAX_PROCESS_COUNT_PER_REPLICA
      : 1;
    let maxDBConnectionsPerReplicaProcess = Math.floor(
      connectionsPerReplica / maxProcessCountPerReplica
    );

    console.log(`Primary ${process.pid} is running`);
    console.log(`TypeOrmConfigService settings:
        totalMaxConnections: (${totalMaxConnections}),
        maxReplicas: (${maxReplicas}),
        connectionsPerReplica: (${connectionsPerReplica}),
        maxProcessCountPerReplica: (${maxProcessCountPerReplica}),
        maxDBConnectionsPerReplicaProcess: (${maxDBConnectionsPerReplicaProcess})`);

    const postgresConfig: TypeOrmModuleOptions = {
      type: 'postgres',
      host: process.env.DB_HOST,
      port: parseInt(process.env.DB_PORT) || 5432,
      database: process.env.DB_NAME,
      username: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
      ssl: process.env.DB_SSL === 'true' ? {
        rejectUnauthorized: false,
        minVersion: 'TLSv1.2',
        maxVersion: 'TLSv1.3'
      } : false,
      extra: process.env.DB_SSL === 'true' ? {
        ssl: {
          rejectUnauthorized: false,
          sslmode: 'require'
        }
      } : undefined,
      entities: ['dist/**/*.entity.{ts,js}'],
      migrations: ['dist/**/migrations/*.{ts,js}'],
      migrationsTableName: 'typeorm_migrations',
      logger: 'advanced-console',
      logging: ['warn', 'error'],
      synchronize: false,
      autoLoadEntities: true,
      maxQueryExecutionTime: 2000,
    };

    console.log('PostgreSQL Configuration:', postgresConfig);
    return postgresConfig;
  }
}
