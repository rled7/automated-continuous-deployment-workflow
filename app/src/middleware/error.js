import { STATUS_CODES } from 'http';
import { ZodError } from 'zod';
import logger from '../lib/logger.js';

/**
 * Express error handler. Must be mounted last (4-argument signature).
 * - ZodError → 400 with issues list
 * - err.statusCode → that status
 * - otherwise → 500
 * 5xx responses say only "Internal Server Error": the message of an
 * unexpected error (a driver error, say) is logged, not sent to the client.
 */
// eslint-disable-next-line no-unused-vars
const errorHandler = (err, req, res, next) => {
  const requestId = req.id;

  if (err instanceof ZodError) {
    logger.warn({ requestId, issues: err.issues }, 'Validation error');
    return res.status(400).json({
      error: {
        message: 'Validation failed',
        requestId,
        issues: err.issues,
      },
    });
  }

  const status = err.statusCode || 500;
  logger.error({ requestId, err, status }, 'Request error');

  return res.status(status).json({
    error: {
      message: status >= 500 ? 'Internal Server Error' : err.message || STATUS_CODES[status],
      requestId,
    },
  });
};

export default errorHandler;
