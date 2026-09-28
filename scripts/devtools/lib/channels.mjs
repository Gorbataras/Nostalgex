// Channel pool builder — filter logic lives in scripts/channel-filter.js (shared
// with plex-tuner.html). This module loads channels.json + manifest for Node devtools.

import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadManifest } from "./memberships.mjs";

const require = createRequire(import.meta.url);
const CF = require("../../nostalgex-channel-filter.cjs");

const __dirname = dirname(fileURLToPath(import.meta.url));
const CHANNELS_JSON = join(__dirname, "..", "..", "..", "Nostalgex", "Nostalgex", "channels.json");

const UNSUPPORTED_RULE_KEYS = [
  "excludeKeywords",
  "networks",
  "excludeNetworks",
  "ratingMin",
];
const PARTIAL_RULE_KEYS = ["productionCompanies", "studios"];

let cached = null;

export async function loadChannels() {
  if (cached) return cached;
  const text = await readFile(CHANNELS_JSON, "utf8");
  cached = JSON.parse(text);
  return cached;
}

export function unsupportedRulesFor(channel) {
  if (!channel.rules) return [];
  return UNSUPPORTED_RULE_KEYS.filter((k) => {
    const v = channel.rules[k];
    return Array.isArray(v) ? v.length > 0 : v != null;
  });
}

export function partialRulesFor(channel) {
  if (!channel.rules) return [];
  return PARTIAL_RULE_KEYS.filter((k) => {
    const v = channel.rules[k];
    return Array.isArray(v) ? v.length > 0 : v != null;
  });
}

export const channelRequiresAnimationGenre = CF.channelRequiresAnimationGenre;
export const itemHasAnimationGenre = CF.itemHasAnimationGenre;
export const itemPasses = CF.itemPasses;

/** Build channel pool with manifest + rule parity to the tvOS app. */
export async function poolFor(channel, allItems, nowSec = Math.floor(Date.now() / 1000)) {
  const manifest = await loadManifest();
  return CF.filterPool(allItems, channel, { manifest, nowSec });
}
