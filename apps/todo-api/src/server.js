const express = require('express');
const { Pool } = require('pg');
const client = require('prom-client');

const app = express();
app.use(express.json());

const pool = new Pool({
  host: process.env.DB_HOST || 'tododb-rw',
  port: Number(process.env.DB_PORT || 5432),
  database: process.env.DB_NAME || 'tododb',
  user: process.env.DB_USER || 'todo',
  password: process.env.DB_PASSWORD,
  max: 10,
  connectionTimeoutMillis: 3000
});

client.collectDefaultMetrics({ prefix: 'todo_api_' });
const requests = new client.Counter({
  name: 'todo_api_http_requests_total',
  help: 'HTTP requests handled by todo-api',
  labelNames: ['method', 'route', 'status']
});
const duration = new client.Histogram({
  name: 'todo_api_http_request_duration_seconds',
  help: 'HTTP request latency',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2]
});

app.use((req, res, next) => {
  const stop = duration.startTimer();
  res.on('finish', () => {
    const route = req.route?.path || req.path;
    const labels = { method: req.method, route, status: String(res.statusCode) };
    requests.inc(labels);
    stop(labels);
  });
  next();
});

async function initialize() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS tasks (
      id BIGSERIAL PRIMARY KEY,
      title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 250),
      done BOOLEAN NOT NULL DEFAULT FALSE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);
}

app.get('/healthz', (_req, res) => res.status(200).json({ status: 'alive' }));

app.get('/readyz', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.status(200).json({ status: 'ready' });
  } catch (error) {
    res.status(503).json({ status: 'not-ready', error: error.message });
  }
});

app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.send(await client.register.metrics());
});

app.get('/tasks', async (_req, res, next) => {
  try {
    const { rows } = await pool.query('SELECT * FROM tasks ORDER BY id DESC');
    res.json(rows);
  } catch (error) { next(error); }
});

app.post('/tasks', async (req, res, next) => {
  try {
    const title = String(req.body.title || '').trim();
    if (!title || title.length > 250) return res.status(400).json({ error: 'title must contain 1-250 characters' });
    const { rows } = await pool.query(
      'INSERT INTO tasks(title, done) VALUES($1, $2) RETURNING *',
      [title, Boolean(req.body.done)]
    );
    res.status(201).json(rows[0]);
  } catch (error) { next(error); }
});

app.get('/tasks/:id', async (req, res, next) => {
  try {
    const { rows } = await pool.query('SELECT * FROM tasks WHERE id=$1', [req.params.id]);
    if (!rows[0]) return res.status(404).json({ error: 'task not found' });
    res.json(rows[0]);
  } catch (error) { next(error); }
});

app.put('/tasks/:id', async (req, res, next) => {
  try {
    const title = req.body.title === undefined ? null : String(req.body.title).trim();
    if (title !== null && (!title || title.length > 250)) return res.status(400).json({ error: 'invalid title' });
    const done = req.body.done === undefined ? null : Boolean(req.body.done);
    const { rows } = await pool.query(
      `UPDATE tasks SET title=COALESCE($1,title), done=COALESCE($2,done), updated_at=NOW()
       WHERE id=$3 RETURNING *`,
      [title, done, req.params.id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'task not found' });
    res.json(rows[0]);
  } catch (error) { next(error); }
});

app.delete('/tasks/:id', async (req, res, next) => {
  try {
    const result = await pool.query('DELETE FROM tasks WHERE id=$1', [req.params.id]);
    if (!result.rowCount) return res.status(404).json({ error: 'task not found' });
    res.status(204).send();
  } catch (error) { next(error); }
});

app.use((error, _req, res, _next) => {
  console.error(error);
  res.status(500).json({ error: 'internal server error' });
});

const port = Number(process.env.PORT || 8080);
initialize()
  .then(() => app.listen(port, '0.0.0.0', () => console.log(`todo-api listening on ${port}`)))
  .catch((error) => {
    console.error('database initialization failed', error);
    process.exit(1);
  });
