import { randomUUID } from 'crypto';

/**
 * Express middleware that reads x-request-id header or generates a UUID,
 * sets req.id, and echoes it back in the response header.
 */
const requestId = (req, res, next) => {
  const id = req.headers['x-request-id'] || randomUUID();
  req.id = id;
  res.setHeader('x-request-id', id);
  next();
};

export default requestId;
