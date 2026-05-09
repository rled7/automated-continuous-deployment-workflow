import pino from 'pino';

// Default to production-style JSON logs. Pretty-print is opt-in via NODE_ENV=development
// AND requires pino-pretty (devDependency, not installed in the production image).
const env = process.env.NODE_ENV || 'production';
const usePretty = env === 'development';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  transport: usePretty
    ? { target: 'pino-pretty', options: { colorize: true } }
    : undefined,
});

export default logger;
