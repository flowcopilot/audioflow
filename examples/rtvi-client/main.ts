import "@fontsource-variable/bricolage-grotesque/standard.css";
import "@fontsource/ibm-plex-mono/400.css";
import "./theme.css";
import { PipecatClient, LogLevel } from "@pipecat-ai/client-js";
import { AudioFlowTransport } from "./transport.ts";
let client: PipecatClient | undefined;
const input = (id: string) => document.getElementById(id) as HTMLInputElement;
const status = (message: string) => {
  document.getElementById("status")!.textContent += message + "\n";
};
async function run(action: () => Promise<unknown>) {
  try {
    await action();
  } catch (error) {
    status(String(error));
  }
}
document.getElementById("connect")!.onclick = () =>
  void run(async () => {
    if (client) await client.disconnect();
    client = new PipecatClient({
      transport: new AudioFlowTransport(input("url").value),
      enableMic: false,
      enableCam: false,
      callbacks: {
        onLlmRawText: (data) => status(data.text),
        onMessageError: (data) => status(JSON.stringify(data)),
        onTransportStateChanged: (state) => status(state),
        onError: (error) => status(JSON.stringify(error)),
      },
    });
    client.setLogLevel(LogLevel.WARN);
    await client.connect();
  });
document.getElementById("disconnect")!.onclick = () =>
  void run(async () => {
    await client?.disconnect();
    client = undefined;
  });
document.getElementById("chat")!.onsubmit = (event) => {
  event.preventDefault();
  void run(async () => {
    if (!client) throw new Error("Connect first");
    await client.sendText(input("text").value);
  });
};
