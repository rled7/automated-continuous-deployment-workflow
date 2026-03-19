import express from 'express';
const router = express.Router();

router.get('/live', (req, res) => res.json({ status: 'alive' }));
router.get('/ready', (req, res) => {
  // Stub checks
  res.json({ status: 'ready', checks: { database: 'ok', redis: 'ok' } });
});

export default router;

