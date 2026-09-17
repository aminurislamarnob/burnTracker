// Dependency-free local server: serves `public/` and dispatches `/api/<name>`
// to the matching module in `api/`, giving the same routes Vercel does.
//
//   node dev-server.mjs          → http://localhost:3000
//   PORT=4000 node dev-server.mjs
//
// Env vars are read from the process, so `CLAUDE_SESSION_KEYS=… node dev-server.mjs`
// behaves like a configured deployment.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('.', import.meta.url));
const port = Number(process.env.PORT) || 3000;

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

/** Minimal shim of the response helpers the handlers use (`res.status().send()`). */
function decorate(res) {
  res.status = (code) => {
    res.statusCode = code;
    return res;
  };
  res.send = (body) => res.end(body);
  return res;
}

const server = createServer(async (req, res) => {
  decorate(res);
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (url.pathname.startsWith('/api/')) {
    const name = url.pathname.slice(5).replace(/\/+$/, '');
    if (!/^[a-z0-9-]+$/i.test(name)) return res.status(404).send('Not found');
    try {
      const mod = await import(`./api/${name}.js`);
      req.query = Object.fromEntries(url.searchParams);
      await mod.default(req, res);
    } catch (err) {
      if (err?.code === 'ERR_MODULE_NOT_FOUND') return res.status(404).send('Not found');
      console.error(err);
      res.status(500).send(JSON.stringify({ error: String(err?.message || err) }));
    }
    return;
  }

  const rel = url.pathname === '/' ? 'index.html' : normalize(url.pathname).replace(/^(\.\.[/\\])+/, '');
  const file = join(root, 'public', rel);
  try {
    const body = await readFile(file);
    res.setHeader('Content-Type', TYPES[extname(file)] || 'application/octet-stream');
    res.setHeader('Cache-Control', 'no-store');
    res.status(200).send(body);
  } catch {
    res.status(404).send('Not found');
  }
});

server.listen(port, () => console.log(`claude-usages → http://localhost:${port}`));
