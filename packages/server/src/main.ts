import mongoose from 'mongoose';
import p from '../package.json';
import { ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { ExpressAdapter, NestExpressApplication } from '@nestjs/platform-express';
import { AppModule } from './app.module';
import { WINSTON_MODULE_NEST_PROVIDER } from 'nest-winston';
import { WinstonModule } from 'nest-winston';
import * as winston from 'winston';
import { urlencoded } from 'body-parser';
import { readFileSync } from 'fs';
import * as Sentry from '@sentry/node';
import { ProfilingIntegration } from '@sentry/profiling-node';
import { setTimeout as originalSetTimeout } from 'timers';
import { setInterval as originalSetInterval } from 'timers';
import express from 'express';
import cluster from 'cluster';
import * as os from 'os';
import * as https from 'https'; 
import { TLSSocket } from 'tls';
import { SecureContextOptions } from 'tls';
import * as tls from 'tls';
import * as constants from 'constants';
import { ServerOptions } from 'https';

const morgan = require('morgan');

let numProcesses = 1;

if (process.env.MAX_PROCESS_COUNT_PER_REPLICA)
  numProcesses = Math.max(
    1,
    parseInt(process.env.MAX_PROCESS_COUNT_PER_REPLICA)
  );

console.log(`[${process.pid}] Booting up`);

if (cluster.isPrimary) {
  console.log(`Primary ${process.pid} is running`);
  console.log(`[${process.env.LAUDSPEAKER_PROCESS_TYPE}] Starting.`);
  console.log(`Number of processes to create: ${numProcesses}`);
  // Fork workers.
  for (let i = 0; i <numProcesses; i++) {
    let p = cluster.fork();

    console.log(`[${process.pid}] Forked process ${p.process.pid}`);
  }

  cluster.on('exit', (worker, code, signal) => {
    console.log(
      `Worker ${worker.process.pid} died with code: ${code} and signal: ${signal}`
    );
    console.log('Starting a new worker');
    cluster.fork(); // Fork a new worker to replace the one that died
  });
} else {

  function initializeSentry(expressApp) {
    Sentry.init({
      dsn: process.env.SENTRY_DSN_URL_BACKEND,
      environment:
        process.env.SENTRY_ENVIRONMENT ||
        process.env.NODE_ENV ||
        process.env.ENVIRONMENT,
      release: process.env.SENTRY_RELEASE,
      integrations: [
        new Sentry.Integrations.Express({
          app: expressApp,
        }),
        new Sentry.Integrations.Mongo({ useMongoose: true }),
        new Sentry.Integrations.Postgres({ usePgNative: true }),
        new Sentry.Integrations.Http({ tracing: true }),
        new ProfilingIntegration(),
        ...Sentry.autoDiscoverNodePerformanceMonitoringIntegrations(),
      ],
      debug: false,
      // Performance Monitoring
      tracesSampleRate: process.env.NODE_ENV == 'production' ? 0.25 : 1.0,
      // Set sampling rate for profiling - this is relative to tracesSampleRate
      profilesSampleRate: 1.0, // Capture 100% of the transactions, reduce in production!
      maxBreadcrumbs: Number.MAX_SAFE_INTEGER,
    });

    if (process.env.SENTRY_ENVIRONMENT_TAG) {
      Sentry.setTag(
        'laudspeaker_environment',
        process.env.SENTRY_ENVIRONMENT_TAG
      );
    }

    expressApp.use(Sentry.Handlers.requestHandler());
    expressApp.use(Sentry.Handlers.tracingHandler());
    expressApp.use(Sentry.Handlers.errorHandler());
  }

  async function initializeApp(app) {
    let expressApp;

    if (process.env.LAUDSPEAKER_PROCESS_TYPE == 'WEB') {
      const mongooseOptions = process.env.NODE_ENV === 'production' 
        ? { ssl: true, sslValidate: true }
        : {};

      const uri = 'mongodb+srv://2f1YzyuwkogQRbWa:2f1YzyuwkogQRbWa@astrazen.q4mjj.mongodb.net/?authSource=admin';
      await mongoose.connect(process.env.MONGODB_URI || uri, mongooseOptions);

      expressApp = express();

      app = await NestFactory.create<NestExpressApplication>(
        AppModule,
        new ExpressAdapter(expressApp),
        {
          rawBody: true,
          logger: WinstonModule.createLogger({
            transports: [
              new winston.transports.Console({
                format: winston.format.combine(
                  winston.format.timestamp(),
                  winston.format.json()
                )
              })
            ]
          })
        }
      );

      if (process.env.SERVE_CLIENT_FROM_NEST) app.setGlobalPrefix('api');
      app.enableCors();
      app.use(express.json({ limit: '50mb' }));
      app.use(express.urlencoded({ limit: '50mb', extended: true }));

      const rawBodyBuffer = (req, res, buf, encoding) => {
        if (buf && buf.length) {
          req.rawBody = buf.toString(encoding || 'utf8');
        }
      };
      app.use(urlencoded({ verify: rawBodyBuffer, extended: true }));

      const morganMiddleware = morgan(
        ':method :url :status :res[content-length] :remote-addr :user-agent - :response-time ms :total-time ms',
        {
          stream: {
            // Configure Morgan to use our custom logger with the http severity
            write: (message) => logger.log(message.trim(), AppModule.name),
          },
        }
      );
      app.use(morganMiddleware);

      app.useGlobalPipes(
        new ValidationPipe({
          whitelist: true,
          transform: true,
          exceptionFactory: (errors) =>
            console.log(JSON.stringify(errors, null, 2)),
        })
      );
    } else {
      app = await NestFactory.createApplicationContext(AppModule);
    }

    const logger = app.get(WINSTON_MODULE_NEST_PROVIDER);

    // Starts listening for shutdown hooks
    app.enableShutdownHooks();
    
    app.useLogger(logger);

    return app;
  }

  async function bootstrap() {
    const expressApp = express();
    const app = await NestFactory.create<NestExpressApplication>(
      AppModule,
      new ExpressAdapter(expressApp),
      {
        logger: WinstonModule.createLogger({
          instance: winston.createLogger({
            level: 'info',
            format: winston.format.json(),
            transports: [new winston.transports.Console()],
          }),
        }),
      }
    );

    await initializeSentry(app);
    await initializeApp(app);
  
    const port = process.env.PORT || 3001;
    await app.listen(port, '0.0.0.0', () => {
      console.log(`Application is running on port ${port}`);
    });
  }

  bootstrap();
}
