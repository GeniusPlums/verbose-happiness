import { TypeOrmOptionsFactory, TypeOrmModuleOptions } from '@nestjs/typeorm';

export class TypeOrmConfigService implements TypeOrmOptionsFactory {
  public createTypeOrmOptions(): TypeOrmModuleOptions {
    console.log('Database Environment Variables:', {
      DATABASE_HOST: process.env.DATABASE_HOST,
      DATABASE_PORT: process.env.DATABASE_PORT,
      DATABASE_NAME: process.env.DATABASE_NAME,
      DATABASE_USER: process.env.DATABASE_USER,
      DATABASE_SSL: process.env.DATABASE_SSL,
      NODE_ENV: process.env.NODE_ENV
    });

    const postgresConfig: TypeOrmModuleOptions = {
      type: 'postgres',
      host: process.env.DATABASE_HOST,
      port: parseInt(process.env.DATABASE_PORT) || 5432,
      database: process.env.DATABASE_NAME,
      username: process.env.DATABASE_USER,
      password: process.env.DATABASE_PASSWORD,
      ssl: process.env.DATABASE_SSL === 'true' ? {
        rejectUnauthorized: false,
        minVersion: 'TLSv1.2',
        maxVersion: 'TLSv1.3'
      } : false,
      entities: ['dist/**/*.entity.{ts,js}'],
      migrations: ['dist/**/migrations/*.{ts,js}'],
      migrationsTableName: 'typeorm_migrations',
      logger: 'advanced-console',
      logging: ['warn', 'error'],
      synchronize: process.env.SYNCHRONIZE === 'true',
      autoLoadEntities: true,
      maxQueryExecutionTime: 2000,
    };

    console.log('PostgreSQL Configuration:', postgresConfig);
    return postgresConfig;
  }
}
