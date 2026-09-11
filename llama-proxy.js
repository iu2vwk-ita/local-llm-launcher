// llama-proxy.js - bridge between OpenCode and llama.cpp.
// Fixes "System message must be at the beginning" (Qwen) and
// "roles must alternate" (Mistral) by merging consecutive system/user messages.
// Listens on 1235 (OpenCode config) -> forwards to 1234 (switch-model.bat).
// Works with ANY model: llama-server uses the template embedded in the GGUF.
const http = require('http');

const UPSTREAM = { host: '127.0.0.1', port: 1234 };
const PORT = 1235;

// Merge consecutive system-system and user-user; map 'developer' -> 'system'.
function normalize(messages) {
  const out = [];
  for (const m of messages) {
    const role = m.role === 'developer' ? 'system' : m.role;
    const last = out[out.length - 1];
    if (last && last.role === role && (role === 'system' || role === 'user')) {
      last.content = (last.content || '') + '\n\n' + (m.content || '');
    } else {
      out.push({ ...m, role });
    }
  }
  return out;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');

  // GET /v1/models - simple pass-through
  if (req.method === 'GET' && url.pathname === '/v1/models') {
    http.get({ ...UPSTREAM, path: url.pathname }, (up) => {
      res.writeHead(up.statusCode, up.headers);
      up.pipe(res);
    }).on('error', () => { res.writeHead(502); res.end('proxy: llama-server down'); });
    return;
  }

  if (req.method !== 'POST') { res.writeHead(404); res.end(); return; }

  let buf = '';
  req.on('data', (c) => (buf += c));
  req.on('end', () => {
    try {
      const body = JSON.parse(buf);
      if (Array.isArray(body.messages)) {
        body.messages = normalize(body.messages);
        buf = JSON.stringify(body);
      }
    } catch { /* leave the body untouched */ }

    const upReq = http.request(
      {
        ...UPSTREAM,
        path: url.pathname + url.search,
        method: 'POST',
        headers: { ...req.headers, 'content-length': Buffer.byteLength(buf) },
      },
      (up) => {
        res.writeHead(up.statusCode, up.headers);
        up.pipe(res); // streaming SSE pass-through
      }
    );
    upReq.on('error', () => { res.writeHead(502); res.end('proxy: llama-server down'); });
    upReq.end(buf);
  });
});

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') { console.log('proxy already running on :' + PORT); process.exit(0); }
  throw e;
});

server.listen(PORT, '127.0.0.1', () =>
  console.log('llama-proxy: :' + PORT + ' -> llama-server :' + UPSTREAM.port + ' (merges system messages)')
);
