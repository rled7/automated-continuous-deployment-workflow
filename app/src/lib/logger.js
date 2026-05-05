import pino from 'pino';

const env = process.env.NODE_ENV || 'development';
const usePretty = env === 'development';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  transport: usePretty
    ? { target: 'pino-pretty', options: { colorize: true } }
    : undefined,
});

export default logger;
