// Serves this directory on PAGE_PORT (8080), for index.html and livekit-client.
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize } from "node:path";

const root = new URL(".", import.meta.url).pathname;
const types = { ".html": "text/html", ".js": "text/javascript", ".map": "application/json" };

export function serve(port = Number(process.env.PAGE_PORT ?? 8080)) {
  const server = createServer(async (req, res) => {
    const path = normalize(join(root, new URL(req.url, "http://x").pathname));
    if (!path.startsWith(root)) return res.writeHead(403).end();
    try {
      const file = path.endsWith("/") ? join(path, "index.html") : path;
      res.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" });
      res.end(await readFile(file));
    } catch {
      res.writeHead(404).end();
    }
  });
  return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve(server)));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const server = await serve();
  console.log(`http://127.0.0.1:${server.address().port}/`);
}
