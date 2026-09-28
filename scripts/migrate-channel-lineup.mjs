#!/usr/bin/env node
/**
 * One-shot channel ID/number realignment (v14 lineup).
 * Run: node scripts/migrate-channel-lineup.mjs
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

/** old id → new id (number matches id) */
const ID_MAP = {
  // NOSTALGEX slot cleanup
  10: 3,
  11: 8,
  // Music → 150s
  8: 150,
  13: 151,
  14: 152,
  15: 153,
  16: 154,
  17: 155,
  18: 156,
  19: 157,
  // Decades → 80s
  150: 80,
  151: 81,
  152: 82,
  153: 83,
  154: 84,
  155: 85,
  // Premium → 60s
  56: 60,
  58: 61,
  71: 62,
  72: 63,
  73: 64,
  74: 65,
  75: 66,
  76: 67,
  78: 68,
  79: 69,
  // Adventureland + sports → 70s
  80: 70,
  81: 71,
  82: 72,
  90: 73,
  91: 74,
  92: 75,
  // Streamers → 120s
  130: 120,
  131: 121,
  132: 122,
  133: 123,
  134: 124,
  135: 125,
  136: 126,
  137: 127,
  138: 128,
  139: 129,
  // Seasonal → 130s
  120: 130,
  121: 131,
  122: 132,
  // After dark → 140s
  70: 140,
  77: 141,
  // Static franchises → 100–106 (sequential)
  100: 100,
  101: 101,
  102: 102,
  103: 103,
  106: 104,
  114: 105,
  115: 106,
  // v14 interim (200s) → 100s
  200: 100,
  201: 101,
  202: 102,
  203: 103,
  204: 104,
  205: 105,
  206: 106,
};

function remapId(oldId) {
  return ID_MAP[oldId] ?? oldId;
}

function remapIdList(ids) {
  return [...new Set(ids.map(remapId))].sort((a, b) => a - b);
}

function migrateChannelsJson() {
  const p = path.join(root, "channels.json");
  const data = JSON.parse(fs.readFileSync(p, "utf8"));
  data.version = 14;

  for (const rule of data.exclusiveRules ?? []) {
    if (rule.channelID != null) rule.channelID = remapId(rule.channelID);
  }

  for (const bundle of data.bundles ?? []) {
    bundle.channelIDs = remapIdList(bundle.channelIDs);
  }

  // Two-phase id swap to avoid collisions
  for (const ch of data.channels) {
    ch.id = 9000 + ch.id;
  }
  for (const ch of data.channels) {
    const oldId = ch.id - 9000;
    const newId = remapId(oldId);
    ch.id = newId;
    ch.number = newId;
  }

  data.channels.sort((a, b) => a.number - b.number);
  fs.writeFileSync(p, JSON.stringify(data, null, 2) + "\n");
  console.log(`Updated ${p} (v14, ${data.channels.length} channels)`);
}

function migrateMemberships() {
  const p = path.join(root, "channels-memberships.json");
  if (!fs.existsSync(p)) {
    console.warn("Skip memberships — file missing");
    return;
  }
  const data = JSON.parse(fs.readFileSync(p, "utf8"));
  let touched = 0;
  for (const entry of Object.values(data.items ?? {})) {
    if (!entry.channels?.length) continue;
    entry.channels = remapIdList(entry.channels);
    touched++;
  }
  fs.writeFileSync(p, JSON.stringify(data, null, 2) + "\n");
  console.log(`Updated ${p} (${touched} manifest entries remapped)`);
}

function migrateExemplars() {
  const p = path.join(root, "scripts/channel-keyword-tuner/exemplars.json");
  if (!fs.existsSync(p)) return;
  const data = JSON.parse(fs.readFileSync(p, "utf8"));
  if (Array.isArray(data.channels)) {
    for (const row of data.channels) {
      if (row.channelId != null) row.channelId = remapId(row.channelId);
      if (row.id != null && row.channelId == null) row.id = remapId(row.id);
    }
  } else if (typeof data === "object") {
    const next = {};
    for (const [key, val] of Object.entries(data)) {
      const numKey = Number(key);
      const newKey = Number.isFinite(numKey) && ID_MAP[numKey] != null ? String(ID_MAP[numKey]) : key;
      next[newKey] = val;
      if (val && typeof val === "object" && val.channelId != null) {
        val.channelId = remapId(val.channelId);
      }
    }
    Object.assign(data, next);
  }
  fs.writeFileSync(p, JSON.stringify(data, null, 2) + "\n");
  console.log(`Updated ${p}`);
}

migrateChannelsJson();
migrateMemberships();
migrateExemplars();
