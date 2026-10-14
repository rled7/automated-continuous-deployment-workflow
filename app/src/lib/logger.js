import pino from 'pino';

const env = process.env.NODE_ENV || 'development';
const usePretty = env === 'development';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  // pino-http logs request and response headers; credentials stay out of the
  // logs. Child loggers (pino-http's included) inherit this.
  redact: [
    'req.headers.authorization',
    'req.headers["proxy-authorization"]',
    'req.headers.cookie',
    'res.headers["set-cookie"]',
  ],
  transport: usePretty
    ? { target: 'pino-pretty', options: { colorize: true } }
    : undefined,
});

export default logger;
