import { createRequire } from 'module';
import pino from 'pino';

const env = process.env.NODE_ENV || 'development';

// pino-pretty is a dev dependency: the production image does not have it, so
// with NODE_ENV unset or "development" there the logs stay JSON instead of
// the transport failing at startup.
const hasPinoPretty = () => {
  try {
    createRequire(import.meta.url).resolve('pino-pretty');
    return true;
  } catch {
    return false;
  }
};
const usePretty = env === 'development' && hasPinoPretty();

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
