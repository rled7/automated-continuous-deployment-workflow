import { randomUUID } from 'crypto';

// Client-supplied IDs end up in logs and response headers: accept only short
// IDs of safe characters (UUIDs and the like), generate one otherwise.
const VALID_ID = /^[A-Za-z0-9._-]{1,64}$/;

/**
 * Express middleware that reads x-request-id header or generates a UUID,
 * sets req.id, and echoes it back in the response header.
 */
const requestId = (req, res, next) => {
  const header = req.headers['x-request-id'];
  const id = typeof header === 'string' && VALID_ID.test(header) ? header : randomUUID();
  req.id = id;
  res.setHeader('x-request-id', id);
  next();
};

export default requestId;
