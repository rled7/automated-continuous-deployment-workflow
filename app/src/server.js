import express from 'express';
import healthRouter from './routes/health.js';

const app = express();
const PORT = process.env.PORT || 3000;
const SHUTDOWN_TIMEOUT_MS = 55_000;

app.use(express.json());
app.use('/health', healthRouter);

app.get('/api/items', (req, res) => {
  res.json([{ id: 1, name: 'demo-item' }]);
});

app.post('/api/items', (req, res) => {
  const { name } = req.body;
  res.status(201).json({ id: Date.now(), name });
});

const server = app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});

const shutdown = (signal) => {
  console.log(`${signal} received, shutting down gracefully`);

  const forceExit = setTimeout(() => {
    console.error('Forced exit after shutdown timeout');
    process.exit(1);
  }, SHUTDOWN_TIMEOUT_MS);
  forceExit.unref();

  server.close((err) => {
    if (err) {
      console.error('Error during server.close:', err);
      process.exit(1);
    }
    console.log('Process terminated');
    process.exit(0);
  });
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

export default server;
