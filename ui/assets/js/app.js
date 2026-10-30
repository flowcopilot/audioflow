import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import "live_base";
import "live_ai_elements";
import { hooks as liveBase } from "phoenix-colocated/live_base";
import { hooks as liveAiElements } from "phoenix-colocated/live_ai_elements";

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ...liveBase, ...liveAiElements },
});

liveSocket.connect();
window.liveSocket = liveSocket;
