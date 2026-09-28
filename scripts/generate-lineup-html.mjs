#!/usr/bin/env node
/** Emit lineup__group blocks for index.html / apple-tv.html from channels.json */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const { channels, bundles } = JSON.parse(fs.readFileSync(path.join(root, "channels.json"), "utf8"));
const byId = Object.fromEntries(channels.map((c) => [c.id, c]));

const labels = {
  nostalgex: "NOSTALGEX",
  kids: "KIDS & FAMILY",
  truecrime: "TRUE CRIME",
  essentials: "ESSENTIALS",
  premium: "PREMIUM",
  "high-rotation": "MUSIC",
  decades: "DECADES",
  adventureland: "ADVENTURELAND",
  sports: "SPORTS",
  franchises: "FRANCHISES",
  streamers: "STUDIOS & STREAMERS",
  seasonal: "SEASONAL",
  adults: "AFTER DARK",
};

function esc(s) {
  return s.replace(/&/g, "&amp;").replace(/'/g, "&#39;");
}

/** Same order as channels.json bundles (sorted by lowest channel number). */
const bundlesByNumber = [...bundles].sort(
  (a, b) => Math.min(...a.channelIDs) - Math.min(...b.channelIDs)
);

const groups = [];
for (const b of bundlesByNumber) {
  const chs = b.channelIDs
    .map((cid) => byId[cid])
    .filter(Boolean)
    .sort((a, b) => a.number - b.number);
  const items = chs
    .map(
      (c) =>
        `        <div class="lineup__item" style="border-color:${c.colorHex};"><span class="lineup__num" style="color:${c.colorHex};">${c.number}</span><span class="lineup__name">${esc(c.name)}</span></div>`
    )
    .join("\n");
  groups.push(`    <div class="lineup__group fade-in">
      <div class="lineup__group-head">
        <span class="lineup__group-name">${labels[b.id] ?? b.name}</span>
        <span class="lineup__group-count">${chs.length} CHANNEL${chs.length === 1 ? "" : "S"}</span>
      </div>
      <div class="lineup__grid">
${items}
      </div>
    </div>`);
}

process.stdout.write(groups.join("\n") + "\n");
