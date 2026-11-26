// Headless check of the durable-call example: a livekit-client user talks to
// the agent, agent node A is killed, node B takes the call over, and the user
// connection never drops. run.sh sets the environment.
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { serve } from "./serve.mjs";

const { SFU_URL, TOKEN, AGENT_A_PID, AGENT_B_CMD } = process.env;
const timeoutMs = Number(process.env.TAKEOVER_TIMEOUT_MS ?? 30000);

async function until(what, check, ms = 20000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await check()) return;
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`timed out: ${what}`);
}

const server = await serve(0);
const browser = await chromium.launch({
  args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", "--autoplay-policy=no-user-gesture-required"],
});
let agentB;

try {
  const page = await browser.newPage();
  const query = new URLSearchParams({ url: SFU_URL, token: TOKEN });
  await page.goto(`http://127.0.0.1:${server.address().port}/?${query}`);
  await page.evaluate(() => window.start());
  const events = () => page.evaluate(() => window.events);
  const bytes = () => page.evaluate(() => window.agentBytes());

  await until("the agent track", async () => (await events()).some((e) => e.type === "subscribed"));
  await until("an agent answer", async () => (await bytes()) > 2000);
  console.log("the agent answers on node A");

  process.kill(Number(AGENT_A_PID), "SIGKILL");
  const killed = Date.now();
  console.log("killed agent node A; starting node B");
  agentB = spawn("sh", ["-c", AGENT_B_CMD], { stdio: ["ignore", "inherit", "inherit"] });

  const before = await bytes();
  await until("an answer from node B", async () => (await bytes()) > before + 2000, timeoutMs);
  console.log(`node B answers ${Date.now() - killed} ms after node A was killed`);

  const all = await events();
  const dropped = all.filter((e) => e.type === "disconnected" || (e.type === "left" && e.identity.startsWith("agent-")));
  if (dropped.length) throw new Error(`the call dropped: ${JSON.stringify(dropped)}`);
  console.log("PASS durable call: the user stayed connected and the agent came back");
} finally {
  await browser.close();
  server.close();
  agentB?.kill("SIGTERM");
}
