// Checks that livekit-client works with the AudioFlow SFU: join over
// /rtc/v1, publish a microphone, subscribe, receive audio, and resume after
// a signal reconnect. The SFU must run at SFU_URL with API_KEY/API_SECRET.
import { createHmac } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { chromium } from "playwright";

const sfu = process.env.SFU_URL ?? "ws://127.0.0.1:7880";
const key = process.env.API_KEY ?? "devkey";
const secret = process.env.API_SECRET ?? "devsecret";
const room = `js-compat-${Date.now()}`;

const b64 = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

function token(identity) {
  const now = Math.floor(Date.now() / 1000);
  const body = `${b64({ alg: "HS256", typ: "JWT" })}.${b64({
    iss: key,
    sub: identity,
    nbf: now,
    exp: now + 600,
    video: { room, roomJoin: true, canPublish: true, canSubscribe: true },
  })}`;
  return `${body}.${createHmac("sha256", secret).update(body).digest("base64url")}`;
}

async function until(what, check, timeoutMs = 15000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error(`timed out: ${what}`);
}

const files = {
  "/": ["page.html", "text/html"],
  "/livekit-client.umd.js": ["node_modules/livekit-client/dist/livekit-client.umd.js", "text/javascript"],
};

const server = createServer(async (req, res) => {
  const file = files[req.url];
  if (!file) return res.writeHead(404).end();
  res.writeHead(200, { "content-type": file[1] }).end(await readFile(new URL(file[0], import.meta.url)));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const page = `http://127.0.0.1:${server.address().port}/`;

const browser = await chromium.launch({
  args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", "--autoplay-policy=no-user-gesture-required"],
});

try {
  const alice = await browser.newPage();
  const bob = await browser.newPage();
  for (const [name, p] of [["alice", alice], ["bob", bob]]) {
    p.on("console", async (m) => {
      if (m.type() !== "error") return;
      const args = await Promise.all(m.args().map((a) => a.jsonValue().catch(() => String(a))));
      console.log(`[${name}]`, JSON.stringify(args).slice(0, 4000));
    });
    await p.goto(page);
  }

  const a = await alice.evaluate(([url, t]) => window.join(url, t, true), [sfu, token("alice")]);
  console.log("alice joined", a.sid);
  const b = await bob.evaluate(([url, t]) => window.join(url, t, false), [sfu, token("bob")]);
  console.log("bob joined", b.sid);

  const subscribed = () => bob.evaluate(() => window.events.some((e) => e.type === "subscribed" && e.identity === "alice"));
  await until("bob subscribes to alice", subscribed);
  await until("bob receives audio", async () => (await bob.evaluate(() => window.bytesReceived())) > 2000);
  console.log("bob receives alice's audio");

  await until("alice sees bob", () => alice.evaluate(() => window.events.some((e) => e.type === "joined" && e.identity === "bob")));

  // A dropped signaling socket resumes the same session; media continues.
  await bob.evaluate(() => window.simulate("signal-reconnect"));
  await until("bob resumes", () => bob.evaluate(() => window.events.some((e) => e.type === "reconnected")));
  const before = await bob.evaluate(() => window.bytesReceived());
  await until("audio continues after resume", async () => (await bob.evaluate(() => window.bytesReceived())) > before + 2000);
  console.log("bob resumed and still receives audio");

  await bob.evaluate(() => window.room.disconnect());
  await until("alice sees bob leave", () => alice.evaluate(() => window.events.some((e) => e.type === "left" && e.identity === "bob")));
  console.log("PASS livekit-client compatibility");
} finally {
  await browser.close();
  server.close();
}
