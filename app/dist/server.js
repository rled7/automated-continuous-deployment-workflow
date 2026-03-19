import express from 'express';
import healthRouter from './routes/health.js';

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(express.json());

// Health routes
app.use('/health', healthRouter);

// API routes
app.get('/api/items', (req, res) => {
  res.json([{ id: 1, name: 'demo-item' }]);
});

app.post('/api/items', (req, res) => {
  const { name } = req.body;
  res.status(201).json({ id: Date.now(), name });
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down gracefully');
  server.close(() => {
    console.log('Process terminated');
  });
});

const server = app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});

export default server;

