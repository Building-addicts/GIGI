#!/usr/bin/env node
//
// analyze-router-trace.mjs
//
// Reads gigi-router-trace.jsonl (downloaded from the device's
// Application Support container via Xcode → Devices and Simulators →
// app container download) and prints a routing report:
//
//   - decision counts by tier and tool
//   - confidence histogram
//   - latency percentiles
//   - reprompt rate + tier transitions (prev → new) when reprompts fire
//   - low-confidence + empty-tool dispatches (likely problem cases)
//
// Usage:
//   node scripts/analyze-router-trace.mjs <path/to/gigi-router-trace.jsonl>
//
// Output: human-readable Markdown to stdout. Pipe to a file or `less`.

import { readFileSync, existsSync } from "node:fs";
import { argv, exit } from "node:process";

const filePath = argv[2];
if (!filePath) {
  console.error("usage: node scripts/analyze-router-trace.mjs <path-to-jsonl>");
  exit(2);
}
if (!existsSync(filePath)) {
  console.error(`file not found: ${filePath}`);
  exit(1);
}

const raw = readFileSync(filePath, "utf8");
const entries = [];
for (const line of raw.split("\n")) {
  const s = line.trim();
  if (!s) continue;
  try {
    entries.push(JSON.parse(s));
  } catch {
    // tolerate truncation at file tail
  }
}

if (entries.length === 0) {
  console.error("no entries parsed");
  exit(1);
}

// ---------- aggregates ----------

const tierCounts = new Map();
const toolCounts = new Map();
const pathCounts = new Map();
const confBuckets = { low: 0, mid: 0, high: 0 }; // <0.5, 0.5–0.8, ≥0.8
const latencies = [];
const repromptTransitions = new Map(); // "prevTier → newTier"
const repromptIds = new Set();
const lowConf = []; // < 0.5
const emptyTool = []; // tool === "" or missing
const byId = new Map();

for (const e of entries) byId.set(e.id, e);

for (const e of entries) {
  tierCounts.set(e.tier, (tierCounts.get(e.tier) ?? 0) + 1);
  toolCounts.set(e.tool || "(none)", (toolCounts.get(e.tool || "(none)") ?? 0) + 1);
  const p = e.path ?? "(none)";
  pathCounts.set(p, (pathCounts.get(p) ?? 0) + 1);

  const c = e.confidence ?? 0;
  if (c < 0.5) confBuckets.low++;
  else if (c < 0.8) confBuckets.mid++;
  else confBuckets.high++;

  if (typeof e.latencyMs === "number" && e.latencyMs > 0) latencies.push(e.latencyMs);

  if (e.repromptOfId) {
    repromptIds.add(e.id);
    const prev = byId.get(e.repromptOfId);
    if (prev) {
      const k = `${prev.tier} → ${e.tier}`;
      repromptTransitions.set(k, (repromptTransitions.get(k) ?? 0) + 1);
    }
  }

  if (c < 0.5) lowConf.push(e);
  if (!e.tool) emptyTool.push(e);
}

const percentile = (arr, p) => {
  if (arr.length === 0) return 0;
  const sorted = [...arr].sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
};

const fmtTable = (map, label) => {
  const rows = [...map.entries()].sort((a, b) => b[1] - a[1]);
  const total = rows.reduce((s, [, n]) => s + n, 0) || 1;
  const out = [`| ${label} | count | % |`, `|---|---:|---:|`];
  for (const [k, n] of rows) {
    out.push(`| ${k} | ${n} | ${((n / total) * 100).toFixed(1)} |`);
  }
  return out.join("\n");
};

const first = entries[0];
const last = entries[entries.length - 1];

// ---------- report ----------

console.log(`# Router trace analysis

- file: \`${filePath}\`
- entries: **${entries.length}**
- window: ${first.timestamp} → ${last.timestamp}

## Tier distribution

${fmtTable(tierCounts, "tier")}

## Tool distribution

${fmtTable(toolCounts, "tool")}

## Path distribution

${fmtTable(pathCounts, "path")}

## Confidence

- **low** (<0.5): ${confBuckets.low}
- **mid** (0.5–0.8): ${confBuckets.mid}
- **high** (≥0.8): ${confBuckets.high}

## Latency (ms)

- samples: ${latencies.length}
- p50: ${percentile(latencies, 50)}
- p95: ${percentile(latencies, 95)}
- max: ${latencies.length ? Math.max(...latencies) : 0}

### Top 5 slowest

${[...entries]
  .filter((e) => typeof e.latencyMs === "number")
  .sort((a, b) => b.latencyMs - a.latencyMs)
  .slice(0, 5)
  .map((e) => `- ${e.latencyMs}ms · ${e.tier}/${e.tool} · "${(e.utterance ?? "").slice(0, 80)}"`)
  .join("\n") || "(no latency data)"}

## Reprompts

- count: **${repromptIds.size}** (${((repromptIds.size / entries.length) * 100).toFixed(1)}% of all turns)

### Tier transitions (prev → new) when reprompt fires

${
  repromptTransitions.size
    ? [...repromptTransitions.entries()]
        .sort((a, b) => b[1] - a[1])
        .map(([k, n]) => `- ${k}: ${n}`)
        .join("\n")
    : "(none)"
}

## Likely problem cases

### Low-confidence dispatches (<0.5) — most recent 10

${
  lowConf.length
    ? lowConf
        .slice(-10)
        .map(
          (e) =>
            `- [${e.timestamp}] conf=${(e.confidence ?? 0).toFixed(2)} · ${e.tier}/${e.tool} · "${(e.utterance ?? "").slice(0, 80)}"`,
        )
        .join("\n")
    : "(none)"
}

### Empty-tool entries — most recent 10

${
  emptyTool.length
    ? emptyTool
        .slice(-10)
        .map((e) => `- [${e.timestamp}] tier=${e.tier} · "${(e.utterance ?? "").slice(0, 80)}"`)
        .join("\n")
    : "(none)"
}
`);
