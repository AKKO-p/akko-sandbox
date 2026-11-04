// MCP tool calls under k6, over the server's streamable HTTP: each session sends
// initialize, then notifications/initialized with the Mcp-Session-Id the server gave,
// then tools/call. Validated against the MCP Inspector by bench/perf/validate.sh
// (the same answers, once durations are removed) before any measure.
//
//   docker run --rm --network <project>_default -v $PWD/bench/perf:/bench:ro -v <out>:/out \
//     -e TOKENS=<token,token,...> -e CALLS_FILE=/bench/calls.json grafana/k6:1.3.0 run /bench/mcp.js
//
// Environment:
//   MCP_URL      http://mcp:3000/mcp
//   TOKENS       bearer tokens, comma separated; virtual user n takes token n mod count,
//                so that the per-caller caches work as in production
//   CALLS_FILE   JSON list of {"tool", "arguments"}; iteration i calls entry i mod count
//   VUS          virtual users (1); ITERATIONS total iterations (the number of calls);
//                DURATION, when set, replaces ITERATIONS (30s, 5m)
//   SESSION      "iteration" (a fresh session per call, as the Inspector does) or "vu"
//                (one session per virtual user, kept)
//   ECHO         "1" prints each answer's text as one JSON line to the console
//   SUMMARY      the summary file (/out/summary.json)
import http from "k6/http";
import { check } from "k6";
import { Counter, Trend } from "k6/metrics";
import exec from "k6/execution";

const URL = __ENV.MCP_URL || "http://mcp:3000/mcp";
const TOKENS = (__ENV.TOKENS || "").split(",").filter((t) => t);
const CALLS = JSON.parse(open(__ENV.CALLS_FILE || "/bench/calls.json"));
const SESSION = __ENV.SESSION || "iteration";
const ECHO = __ENV.ECHO === "1";
const PROTOCOL = "2025-06-18";

const callTime = new Trend("mcp_call_duration", true);
const sessionTime = new Trend("mcp_session_duration", true);
const errors = new Counter("mcp_errors");

const vus = parseInt(__ENV.VUS || "1", 10);
const trendStats = ["avg", "min", "med", "max", "p(95)", "p(99)", "count"];
export const options = __ENV.DURATION
  ? { vus, duration: __ENV.DURATION, summaryTrendStats: trendStats }
  : {
      summaryTrendStats: trendStats,
      scenarios: { calls: { executor: "shared-iterations", vus, iterations: parseInt(__ENV.ITERATIONS || `${CALLS.length}`, 10), maxDuration: "30m" } },
    };

let session = null; // this virtual user's session, when SESSION=vu
let nextId = 1;

function headers(token, sid, version) {
  const h = { "Content-Type": "application/json", Accept: "application/json, text/event-stream", Authorization: `Bearer ${token}` };
  if (sid) h["Mcp-Session-Id"] = sid;
  if (version) h["MCP-Protocol-Version"] = version;
  return h;
}

// A JSON-RPC answer, from a JSON body or from the data lines of an event stream.
function rpc(res, id) {
  const type = (res.headers["Content-Type"] || "").toLowerCase();
  if (type.includes("text/event-stream")) {
    for (const line of (res.body || "").split("\n")) {
      if (!line.startsWith("data:")) continue;
      try {
        const msg = JSON.parse(line.slice(5).trim());
        if (msg.id === id) return msg;
      } catch (e) {
        // not a JSON-RPC message: an event the client does not read
      }
    }
    return null;
  }
  try {
    return JSON.parse(res.body);
  } catch (e) {
    return null;
  }
}

function open_session(token) {
  const t0 = Date.now();
  const id = nextId++;
  const init = http.post(
    URL,
    JSON.stringify({ jsonrpc: "2.0", id, method: "initialize", params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: "akko-bench-k6", version: "1" } } }),
    { headers: headers(token), tags: { step: "initialize" } },
  );
  const msg = rpc(init, id);
  const sid = init.headers["Mcp-Session-Id"];
  if (!check(init, { "initialize: 200 with a session id": (r) => r.status === 200 && !!sid && !!msg && !!msg.result })) {
    errors.add(1, { step: "initialize" });
    return null;
  }
  const version = msg.result.protocolVersion || PROTOCOL;
  const ack = http.post(URL, JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }), {
    headers: headers(token, sid, version),
    tags: { step: "initialized" },
  });
  if (!check(ack, { "initialized: 202": (r) => r.status === 202 || r.status === 200 })) {
    errors.add(1, { step: "initialized" });
    return null;
  }
  sessionTime.add(Date.now() - t0);
  return { token, sid, version };
}

function close_session(s) {
  http.del(URL, null, { headers: headers(s.token, s.sid, s.version), tags: { step: "close" } });
}

export default function () {
  const token = TOKENS[(exec.vu.idInTest - 1) % TOKENS.length];
  const index = exec.scenario.iterationInTest % CALLS.length;
  const call = CALLS[index];
  let s = SESSION === "vu" ? session : null;
  if (!s) {
    s = open_session(token);
    if (!s) return;
    if (SESSION === "vu") session = s;
  }
  const id = nextId++;
  const res = http.post(URL, JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name: call.tool, arguments: call.arguments || {} } }), {
    headers: headers(s.token, s.sid, s.version),
    tags: { step: "tools/call", tool: call.tool },
  });
  callTime.add(res.timings.duration, { tool: call.tool });
  const msg = rpc(res, id);
  const ok = check(res, { "tools/call: 200 with a result": (r) => r.status === 200 && !!msg && !!msg.result });
  if (!ok) errors.add(1, { step: "tools/call", tool: call.tool });
  if (ECHO) {
    const text = ok && msg.result.content && msg.result.content[0] ? msg.result.content[0].text : null;
    console.log(JSON.stringify({ index, tool: call.tool, text }));
  }
  if (SESSION !== "vu") close_session(s);
}

export function handleSummary(data) {
  const out = {};
  const m = data.metrics.mcp_call_duration;
  out.stdout = m
    ? `mcp_call_duration p50 ${m.values.med.toFixed(1)} ms, p95 ${m.values["p(95)"].toFixed(1)} ms, p99 ${(m.values["p(99)"] || 0).toFixed(1)} ms, ` +
      `${m.values.count || data.metrics.iterations.values.count} calls, errors ${(data.metrics.mcp_errors || { values: { count: 0 } }).values.count}\n`
    : "no call measured\n";
  out[__ENV.SUMMARY || "/out/summary.json"] = JSON.stringify(data, null, 2);
  return out;
}
