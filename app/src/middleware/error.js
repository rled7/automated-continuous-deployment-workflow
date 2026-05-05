import { ZodError } from 'zod';
import logger from '../lib/logger.js';

/**
 * Express error handler. Must be mounted last (4-argument signature).
 * - ZodError → 400 with issues list
 * - err.statusCode → that status
 * - otherwise → 500
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
      message: err.message || 'Internal Server Error',
      requestId,
    },
  });
};

export default errorHandler;
