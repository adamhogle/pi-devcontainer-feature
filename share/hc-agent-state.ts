// hc (herdr-core) agent state -- reports pi's state to the hc terminal with
// OSC 7501, so `hc get` and the Ovis app show live status for a pi that runs
// inside a dev container (dev-up's hc bridge + bin/dev-pi).
//
// Repo-owned and mounted by dev-up at /opt/pi/agent/extensions/. It is NOT the
// file `herdr integration install pi` manages: that one (herdr-agent-state.ts)
// keeps serving classic herdr over its socket API. This one stays silent unless
// dev-pi marked the process as running in an hc terminal (HC_TERMINAL_ID), so
// host pi and classic panes are untouched and the two never report twice.
//
// Why OSC and not the socket: hc has no per-pane control socket for agents --
// it reads what the terminal's program prints. pi's pty here *is* the hc
// terminal (podman exec -it), so the report reaches the core on its own, with
// nothing mounted and nothing to authenticate.
// @ts-nocheck

const hcTerminal = process.env.HC_TERMINAL_ID;

function enabled() {
  return !!hcTerminal;
}

let reportSeq = Date.now() * 1000;

// Strip anything that would end or corrupt the sequence early: a BEL/ESC, a
// control character, or the ':' that separates fields.
function clean(value) {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.replace(/[\x00-\x1f\x7f\x80-\x9f]/g, " ").replace(/:/g, " ").trim();
  return trimmed.length > 0 ? trimmed.slice(0, 120) : undefined;
}

function sessionRef(ctx) {
  try {
    const id = ctx?.sessionManager?.getSessionId?.();
    if (typeof id === "string" && id.length > 0) {
      return { session: clean(id) };
    }
  } catch {
    // no session yet; report state alone
  }
  return {};
}

function report(state, ctx, message) {
  if (!enabled()) {
    return;
  }
  const fields = [`state=${state}`, "app=pi", `seq=${++reportSeq}`];
  const ref = sessionRef(ctx);
  if (ref.session) {
    fields.push(`session=${ref.session}`);
  }
  const msg = clean(message);
  if (msg) {
    fields.push(`message=${msg}`);
  }
  try {
    process.stdout.write(`\x1b]7501;${fields.join(":")}\x07`);
  } catch {
    // A closed stdout means the terminal is going away; nothing to report to.
  }
}

export default function (pi) {
  if (!enabled()) {
    return;
  }

  let rootSession = false;
  let blockedMessage;

  pi.on("session_start", async (_event, ctx) => {
    // TUI only: RPC/JSON/print modes have no PTY for hc to display, and pi in
    // those modes still reports hasUI -- mode is the reliable gate.
    if (ctx?.mode !== "tui") {
      return;
    }
    rootSession = true;
    report(ctx?.isIdle?.() === false ? "working" : "idle", ctx);
  });

  pi.on("agent_start", (_event, ctx) => {
    if (!rootSession) {
      return;
    }
    report("working", ctx);
  });

  pi.on("agent_settled", (_event, ctx) => {
    if (!rootSession || ctx?.isIdle?.() !== true) {
      return;
    }
    report("idle", ctx);
  });

  // The same event the classic integration uses for tool-level blocks (a
  // waiting approval or a long tool), so a container-side pi blocked on
  // something shows that way in Ovis too.
  pi.events.on("herdr:blocked", (data) => {
    if (!rootSession) {
      return;
    }
    if (data?.active) {
      blockedMessage = data.label;
      report("blocked", undefined, blockedMessage);
    } else {
      blockedMessage = undefined;
      report("idle", undefined);
    }
  });
}
