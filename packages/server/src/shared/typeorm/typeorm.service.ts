import { TypeOrmOptionsFactory, TypeOrmModuleOptions } from '@nestjs/typeorm';
import * as os from 'os';

export class TypeOrmConfigService implements TypeOrmOptionsFactory {
  public createTypeOrmOptions(): TypeOrmModuleOptions {
    console.log('Database Environment Variables:');
    console.log({
      DB_HOST: process.env.DB_HOST,
      DB_PORT: process.env.DB_PORT,
      DB_NAME: process.env.DB_NAME,
      DB_USER: process.env.DB_USER,
      DB_SSL: process.env.DB_SSL,
      MONGODB_URI: process.env.MONGODB_URI
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
        rejectUnauthorized: false
      } : false,
      entities: ['dist/**/*.entity.{ts,js}'],
      migrations: ['dist/**/migrations/*.{ts,js}'],
      migrationsTableName: 'typeorm_migrations',
      logger: 'advanced-console',
      logging: ['warn', 'error'],
      synchronize: false,
      autoLoadEntities: true,
      maxQueryExecutionTime: 2000,
      extra: {
        max: maxDBConnectionsPerReplicaProcess,
        options: '-c lock_timeout=240000ms -c statement_timeout=240000ms -c idle_in_transaction_session_timeout=240000ms',
      },
    };

    console.log('PostgreSQL Configuration:', postgresConfig);
    return postgresConfig;
  }
}
