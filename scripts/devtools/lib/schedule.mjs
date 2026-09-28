// JS port of Nostalgex/Models/ChannelSchedule.swift — same deterministic algorithm
// so the explorer matches what the tvOS app actually plays.

// splitmix64 — matches the Swift impl in ChannelSchedule.swift
function splitmix64(x) {
  // BigInt to keep 64-bit semantics
  let z = (BigInt(x) + 0x9E3779B97F4A7C15n) & 0xFFFFFFFFFFFFFFFFn;
  z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & 0xFFFFFFFFFFFFFFFFn;
  z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & 0xFFFFFFFFFFFFFFFFn;
  z = (z ^ (z >> 31n)) & 0xFFFFFFFFFFFFFFFFn;
  return z;
}

// Interleave items by show — same algorithm as Swift's interleaveByShow
// (round-robin by show key with a seeded shuffle inside each group).
function interleaveByShow(items, seed) {
  const groups = new Map();
  for (const item of items) {
    const key = item.type === "episode" && item.grandparentTitle
      ? item.grandparentTitle
      : `__${item.ratingKey}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(item);
  }
  // Seeded shuffle of each group
  let rngState = splitmix64(BigInt(Math.abs(seed) + 1));
  function next() {
    rngState = splitmix64(rngState);
    return Number(rngState & 0x7FFFFFFFn) / 0x7FFFFFFF;
  }
  for (const list of groups.values()) {
    for (let i = list.length - 1; i > 0; i--) {
      const j = Math.floor(next() * (i + 1));
      [list[i], list[j]] = [list[j], list[i]];
    }
  }
  // Round-robin merge
  const ordered = [...groups.values()];
  const out = [];
  let added = true;
  while (added) {
    added = false;
    for (const list of ordered) {
      if (list.length) {
        out.push(list.shift());
        added = true;
      }
    }
  }
  return out;
}

// Replicates buildSchedule(for:at:) from ChannelSchedule.swift but returns the
// computed window directly. The caller drives multi-window stitching for ranges.
export function buildScheduleAt(channel, pool, atUnixSec) {
  if (!pool.length) return null;
  const totalDurationSec = pool.reduce((acc, i) => acc + (i.duration || 0) * 60, 0);
  if (totalDurationSec <= 0) return null;

  const dayNumber = Math.floor(atUnixSec / 86400);

  const channelHash = Number(splitmix64(BigInt(Math.abs(channel.id) + 1)) % 0x7FFFFFFFFFFFFFFFn);
  const channelBase = channelHash % totalDurationSec;
  const goldenShift = Math.floor(totalDurationSec * 0.6180339887);
  const dailyOffset = (dayNumber * goldenShift) % totalDurationSec;
  // Note: JS modulo can be negative; normalize.
  const posRaw = (atUnixSec + channelBase + dailyOffset) % totalDurationSec;
  const posInLoop = ((posRaw % totalDurationSec) + totalDurationSec) % totalDurationSec;

  let elapsed = 0;
  let currentIndex = 0;
  let offsetInCurrent = 0;
  for (let i = 0; i < pool.length; i++) {
    const itemDur = (pool[i].duration || 0) * 60;
    if (elapsed + itemDur > posInLoop) {
      currentIndex = i;
      offsetInCurrent = posInLoop - elapsed;
      break;
    }
    elapsed += itemDur;
  }

  const currentItemStart = atUnixSec - offsetInCurrent;
  // 6-hour window centered at request, snapped to 30 min
  const windowStartUnix = Math.floor(atUnixSec / 1800) * 1800;
  const windowEndUnix = windowStartUnix + 21600;

  // Walk backward from current item to find the first item that overlaps window
  let walkTime = currentItemStart;
  let walkIndex = currentIndex;
  while (walkTime > windowStartUnix) {
    walkIndex = (walkIndex - 1 + pool.length) % pool.length;
    const dur = (pool[walkIndex].duration || 0) * 60;
    walkTime -= dur;
  }

  // Walk forward, emitting entries until past window end
  const entries = [];
  let entryTime = walkTime;
  let entryIndex = walkIndex;
  while (entryTime < windowEndUnix) {
    const item = pool[entryIndex];
    const dur = (item.duration || 0) * 60;
    const entryEnd = entryTime + dur;
    if (entryEnd > windowStartUnix) {
      entries.push({
        id: `${item.ratingKey}_${entryTime}`,
        item,
        startSec: entryTime,
        endSec: entryEnd,
      });
    }
    entryTime = entryEnd;
    entryIndex = (entryIndex + 1) % pool.length;
    if (dur <= 0) break; // safety against bad data
  }
  return entries;
}

// Build every entry between fromSec..toSec by walking buildScheduleAt in 5h
// steps across overlapping 6h windows. Same approach as the Swift
// buildScheduleRange helper.
export function buildScheduleRange(channel, items, fromSec, toSec) {
  const pool = interleaveByShow(items.filter((i) => (i.duration || 0) > 0), channel.id);
  if (!pool.length) return [];
  const entries = [];
  const seen = new Set();
  let cursor = fromSec;
  const step = 5 * 3600;
  while (cursor < toSec + step) {
    const win = buildScheduleAt(channel, pool, cursor) || [];
    for (const e of win) {
      if (e.startSec < toSec && e.endSec > fromSec && !seen.has(e.id)) {
        seen.add(e.id);
        entries.push(e);
      }
    }
    cursor += step;
  }
  entries.sort((a, b) => a.startSec - b.startSec);
  return entries;
}
