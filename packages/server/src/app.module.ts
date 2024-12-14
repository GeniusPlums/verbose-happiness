import { MiddlewareConsumer, Module, RequestMethod } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { TypeOrmConfigService } from './shared/typeorm/typeorm.service';
import { ApiModule } from './api/api.module';
import { WinstonModule } from 'nest-winston';
import * as winston from 'winston';
import { MongooseModule } from '@nestjs/mongoose';
import { AuthMiddleware } from './api/auth/middleware/auth.middleware';
import { EventsController } from './api/events/events.controller';
import { SlackMiddleware } from './api/slack/middleware/slack.middleware';
import { AppController } from './app.controller';
import { join } from 'path';
import { CronService } from './app.cron.service';
import { ScheduleModule } from '@nestjs/schedule';
import { Customer, CustomerSchema } from './api/customers/schemas/customer.schema';
import { CustomerKeys, CustomerKeysSchema } from './api/customers/schemas/customer-keys.schema';
import { Account } from './api/accounts/entities/accounts.entity';
import { Verification } from './api/auth/entities/verification.entity';
import { EventSchema, Event } from './api/events/schemas/event.schema';
import { EventKeys, EventKeysSchema } from './api/events/schemas/event-keys.schema';
import { Integration } from './api/integrations/entities/integration.entity';
import { Template } from './api/templates/entities/template.entity';
import { Installation } from './api/slack/entities/installation.entity';
import { State } from './api/slack/entities/state.entity';
import { IntegrationsModule } from './api/integrations/integrations.module';
import { ServeStaticModule } from '@nestjs/serve-static';
import { Recovery } from './api/auth/entities/recovery.entity';
import { Segment } from './api/segments/entities/segment.entity';
import { CustomersModule } from './api/customers/customers.module';
import { TemplatesModule } from './api/templates/templates.module';
import { SlackModule } from './api/slack/slack.module';
import { WebhookJobsModule } from './api/webhook-jobs/webhook-jobs.module';
import { WebhookJob } from './api/webhook-jobs/entities/webhook-job.entity';
import { AccountsModule } from './api/accounts/accounts.module';
import { StepsModule } from './api/steps/steps.module';
import { EventsModule } from './api/events/events.module';
import { ModalsModule } from './api/modals/modals.module';
import { WebsocketsModule } from './websockets/websockets.module';
import traverse from 'traverse';
import { klona } from 'klona/full';
import { JourneysModule } from './api/journeys/journeys.module';
import { RedlockModule } from './api/redlock/redlock.module';
import { RedlockService } from './api/redlock/redlock.service';
import { RavenModule } from 'nest-raven';
import { KafkaModule } from './api/kafka/kafka.module';
import { JourneyLocation } from './api/journeys/entities/journey-location.entity';
import { JourneyLocationsService } from './api/journeys/journey-locations.service';
import { SegmentsModule } from './api/segments/segments.module';
import { OrganizationsModule } from './api/organizations/organizations.module';
import { OrganizationInvites } from './api/organizations/entities/organization-invites.entity';
import { redisStore } from 'cache-manager-redis-yet';
import { CacheModule } from '@nestjs/cache-manager';
import { HealthCheckService } from './app.healthcheck.service';
import { QueueModule } from '@/common/services/queue/queue.module';
import { ClickHouseModule } from '@/common/services/clickhouse/clickhouse.module';
import { ChannelsModule } from './api/channels/channels.module';
import { TlsOptions } from 'tls';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { mongodbConfig, redisConfig } from './config/configuration';

const sensitiveKeys = [/cookie/i, /passw(or)?d/i, /^pw$/i, /^pass$/i, /secret/i, /token/i, /api[-._]?key/i];

function isSensitiveKey(keyStr) {
  if (keyStr) {
    return sensitiveKeys.some((regex) => regex.test(keyStr));
  }
}

function redactObject(obj: any) {
  traverse(obj).forEach(function redactor(this: any) {
    if (isSensitiveKey(this.key)) {
      this.update('[REDACTED]');
    }
  });
}

function redact(obj) {
  const copy = klona(obj);
  redactObject(copy);
  const splat = copy[Symbol.for('splat')];
  redactObject(splat);
  return copy;
}

export const formatMongoConnectionString = (mongoConnectionString: string) => {
  if (mongoConnectionString) {
    if (mongoConnectionString.includes('mongodb+srv')) {
      return mongoConnectionString;
    } else if (
      !mongoConnectionString.includes('mongodb') &&
      !mongoConnectionString.includes('?directConnection=true')
    ) {
      return `mongodb://${mongoConnectionString}?directConnection=true`;
    } else if (!mongoConnectionString.includes('mongodb')) {
      return `mongodb://${mongoConnectionString}`;
    } else if (!mongoConnectionString.includes('?directConnection=true')) {
      return `${mongoConnectionString}?directConnection=true`;
    } else return mongoConnectionString;
  }
};

function getProvidersList() {
  let providerList: Array<any> = [
    RedlockService,
    JourneyLocationsService,
    HealthCheckService,
  ];

  if (process.env.LAUDSPEAKER_PROCESS_TYPE == 'CRON') {
    providerList = [...providerList, CronService];
  }

  return providerList;
}

const myFormat = winston.format.printf((info: winston.Logform.TransformableInfo) => {
  let ctx: any = {};
  try {
    ctx = JSON.parse(info.context as string);
  } catch (e) { }

  return `[${info.timestamp}] [${info.level}] [${process.env.LAUDSPEAKER_PROCESS_TYPE}-${process.pid}]${ctx?.class ? ' [Class: ' + ctx?.class + ']' : ''}${ctx?.method ? ' [Method: ' + ctx?.method + ']' : ''}${ctx?.session ? ' [User: ' + ctx?.user + ']' : ''}${ctx?.session ? ' [Session: ' + ctx?.session + ']' : ''}: ${info.message} ${info.stack ? '{stack: ' + info.stack : ''} ${ctx.cause ? 'cause: ' + ctx.cause : ''} ${ctx.message ? 'message: ' + ctx.message : ''} ${ctx.name ? 'name: ' + ctx.name + '}' : ''}`;
});

@Module({
  imports: [
    ConfigModule.forRoot({
      load: [mongodbConfig, redisConfig],
      isGlobal: true,
    }),
    MongooseModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => {
        const config = configService.get('mongodb');
        return {
          uri: formatMongoConnectionString(config.uri),
          useNewUrlParser: true,
          useUnifiedTopology: true,
          retryAttempts: config.retryAttempts,
          connectTimeoutMS: config.connectTimeoutMS,
          socketTimeoutMS: config.socketTimeoutMS,
          ssl: config.ssl,
          tls: config.tls,
          tlsInsecure: config.tlsInsecure,
          directConnection: config.directConnection,
          tlsAllowInvalidCertificates: config.allowInvalidCerts,
          tlsAllowInvalidHostnames: config.allowInvalidHostnames,
          socket: {
            tls: {
              secureProtocol: config.tlsProtocol,
              minVersion: config.tlsMinVersion,
              maxVersion: config.tlsMaxVersion,
              rejectUnauthorized: config.rejectUnauthorized,
              servername: config.host,
              ciphers: config.ciphers || [
                'ECDHE-ECDSA-AES128-GCM-SHA256',
                'ECDHE-RSA-AES128-GCM-SHA256',
                'ECDHE-ECDSA-AES256-GCM-SHA384',
                'ECDHE-RSA-AES256-GCM-SHA384',
                'AES256-GCM-SHA384',
                'AES128-GCM-SHA256'
              ].join(':')
            }
          }
        };
      },
    }),
    CacheModule.registerAsync({
      inject: [ConfigService],
      isGlobal: true,
      useFactory: async (configService: ConfigService) => ({
        store: await redisStore({
          ttl: configService.get('redis.ttl'),
          url: configService.get('redis.url'),
          socket: {
            tls: configService.get('redis.tls')
          },
          commandsQueueMaxLength: 10000
        }),
      }),
    }),
    QueueModule.forRoot({
      connection: {
        uri: process.env.RMQ_CONNECTION_URI ?? 'amqp://localhost',
      },
    }),
    WinstonModule.forRootAsync({
      useFactory: () => ({
        level: process.env.LOG_LEVEL || 'debug',
        transports: [
          new winston.transports.Console({
            handleExceptions: true,
            format: winston.format.combine(
              winston.format((info) => redact(info))(),
              winston.format.colorize({ all: true }),
              winston.format.align(),
              winston.format.errors({ stack: true }),
              winston.format.timestamp({ format: 'YYYY-MM-DD hh:mm:ss.SSS A' }),
              myFormat
            ),
          }),
        ],
      }),
      inject: [],
    }),
    TypeOrmModule.forRootAsync({ useClass: TypeOrmConfigService }),
    ApiModule,
    MongooseModule.forFeature([
      { name: Customer.name, schema: CustomerSchema },
      { name: CustomerKeys.name, schema: CustomerKeysSchema },
      { name: Event.name, schema: EventSchema },
      { name: EventKeys.name, schema: EventKeysSchema },
    ]),
    ScheduleModule.forRoot(),
    TypeOrmModule.forFeature([
      Account,
      Verification,
      Integration,
      Segment,
      Template,
      Installation,
      State,
      Recovery,
      WebhookJob,
      JourneyLocation,
      OrganizationInvites,
    ]),
    ClickHouseModule.register({
      url: `https://${process.env.CLICKHOUSE_HOST}:${process.env.CLICKHOUSE_PORT}`,
      username: process.env.CLICKHOUSE_USER,
      password: process.env.CLICKHOUSE_PASSWORD,
      database: process.env.CLICKHOUSE_DB,
      max_open_connections: 10,
      keep_alive: { enabled: true },
      ssl: { 
        rejectUnauthorized: false,
        minVersion: 'TLSv1.2',
        maxVersion: 'TLSv1.3',
        ciphers: 'TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:ECDHE-RSA-AES128-GCM-SHA256',
        secureProtocol: 'TLSv1_2_method'
      }
    }),
      IntegrationsModule,
      CustomersModule,
      TemplatesModule,
      SlackModule,
      WebhookJobsModule,
      AccountsModule,
      EventsModule,
      ModalsModule,
      WebsocketsModule,
      StepsModule,
      JourneysModule,
      SegmentsModule,
      RedlockModule,
      RavenModule,
      KafkaModule,
      OrganizationsModule,
      ChannelsModule
    ],
    controllers: [AppController],
    providers: getProvidersList(),
  })
  export class AppModule {
    configure(consumer: MiddlewareConsumer) {
      consumer
        .apply(AuthMiddleware)
        .forRoutes(EventsController)
        .apply(SlackMiddleware)
        .forRoutes({ path: '/slack/events', method: RequestMethod.POST });
    }
  }