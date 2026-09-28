// Audit rules — same as the original scripts/audit-library/audit.mjs, refactored
// into a library so the dev server can drive it via HTTP.

import { listSections, listMovieItems, listEpisodeItems, getItemDetails } from "./plex.mjs";

const RULES = [
  (m) => {
    const audio = m.streams.find((s) => s.streamType === 2);
    if (!audio) return { tag: "no-audio-track", severity: "high", reason: "No audio stream detected" };
  },
  (m) => {
    const codecs = m.streams.filter((s) => s.streamType === 2).map((s) => (s.codec || "").toLowerCase());
    const lossless = ["truehd", "dtshd", "dts-hd", "dca", "eac3-atmos"];
    const hit = codecs.find((c) => lossless.some((l) => c.includes(l)));
    if (hit) return { tag: `lossless-audio:${hit}`, severity: "high", reason: `Lossless/object audio (${hit}) — tvOS AVPlayer cannot decode natively, may silently drop` };
  },
  (m) => {
    const c = (m.container || "").toLowerCase();
    if (c === "mkv") return { tag: "container-mkv", severity: "medium", reason: "MKV container forces remux/transcode wrap on tvOS — slow start" };
  },
  (m) => {
    const v = m.streams.find((s) => s.streamType === 1);
    if (!v) return;
    const codec = (v.codec || "").toLowerCase();
    const profile = (v.profile || "").toLowerCase();
    const bitDepth = v.bitDepth;
    if (codec === "hevc" && (bitDepth === 10 || profile.includes("10"))) {
      return { tag: "hevc-10bit", severity: "medium", reason: "HEVC 10-bit can stutter on older Apple TVs; HDR metadata may force transcode" };
    }
    if (codec === "av1") {
      return { tag: "av1-codec", severity: "medium", reason: "AV1 not hardware-decoded on most Apple TV generations — software decode is heavy" };
    }
  },
  (m) => {
    const audioStreams = m.streams.filter((s) => s.streamType === 2);
    if (audioStreams.length > 1) {
      const def = audioStreams.find((s) => s.default);
      const lang = (def?.language || def?.languageCode || "").toLowerCase();
      if (def && lang && !["en", "eng", "english"].includes(lang)) {
        return { tag: `default-audio:${lang}`, severity: "low", reason: `Default audio track is "${def.language || lang}" — viewer may hear wrong language` };
      }
    }
  },
  (m) => {
    const v = m.streams.find((s) => s.streamType === 1);
    if (!v) return;
    const bitrate = Number(v.bitrate || m.bitrate || 0);
    if (bitrate > 60000) return { tag: "very-high-bitrate", severity: "low", reason: `Bitrate ~${Math.round(bitrate / 1000)} Mbps — may stutter on limited bandwidth` };
  },
];

export function severityRank(s) {
  return s === "high" ? 0 : s === "medium" ? 1 : 2;
}

function flattenMedia(item) {
  const out = [];
  for (const media of item.Media || []) {
    for (const part of media.Part || []) {
      out.push({
        ratingKey: item.ratingKey,
        title: item.grandparentTitle ? `${item.grandparentTitle} — ${item.parentTitle || ""} — ${item.title}` : item.title,
        year: item.year || item.parentYear || item.grandparentYear || "",
        file: part.file || "",
        container: media.container || "",
        bitrate: media.bitrate || 0,
        videoCodec: media.videoCodec || "",
        videoProfile: media.videoProfile || "",
        streams: part.Stream || [],
      });
    }
  }
  return out;
}

function evaluate(media) {
  const fired = [];
  for (const rule of RULES) {
    try {
      const hit = rule(media);
      if (hit) fired.push(hit);
    } catch {}
  }
  return fired;
}

// Async generator: yields progress events as the scan runs, then a final result.
// Server side-effect: pushes events into a job record so the UI can poll.
export async function runAudit({ sectionFilter = null, onProgress = () => {} } = {}) {
  const sections = await listSections();
  const filtered = sectionFilter
    ? sections.filter((s) => sectionFilter.has(String(s.key)))
    : sections;

  const findings = [];
  const sectionErrors = [];
  let totalScanned = 0;
  let totalItems = 0;
  let itemErrors = 0;

  for (const section of filtered) {
    onProgress({ phase: "listing", section: section.title });
    let items;
    try {
      items = section.type === "movie"
        ? await listMovieItems(section.key)
        : await listEpisodeItems(section.key);
    } catch (e) {
      // Don't kill the whole audit if one section's listing fails — record it
      // and move on. Common cause: the section is huge and timed out.
      sectionErrors.push({ section: section.title, phase: "listing", error: e.message });
      onProgress({ phase: "section-error", section: section.title, error: e.message });
      continue;
    }
    totalItems += items.length;
    onProgress({ phase: "scanning", section: section.title, total: items.length, done: 0 });

    const concurrency = 6; // dropped from 10 to be gentler on remote Plex servers
    let cursor = 0;
    let sectionDone = 0;
    async function worker() {
      while (cursor < items.length) {
        const i = cursor++;
        const item = items[i];
        try {
          const detail = await getItemDetails(item.ratingKey);
          if (detail) {
            for (const media of flattenMedia(detail)) {
              totalScanned++;
              const fired = evaluate(media);
              if (fired.length) findings.push({ section: section.title, ...media, fired });
            }
          }
        } catch (e) {
          itemErrors++;
          // Log first few item errors to console so we know if something
          // systemic is failing vs. just a couple of bad ratingKeys.
          if (itemErrors <= 3) console.warn(`[audit] item ${item.ratingKey} (${item.title || "?"}): ${e.message}`);
        }
        sectionDone++;
        if (sectionDone % 20 === 0) {
          onProgress({ phase: "scanning", section: section.title, total: items.length, done: sectionDone });
        }
      }
    }
    await Promise.all(Array.from({ length: concurrency }, worker));
    onProgress({ phase: "section-done", section: section.title, total: items.length });
  }

  // Group by tag for the report
  const byTag = new Map();
  for (const f of findings) {
    for (const r of f.fired) {
      if (!byTag.has(r.tag)) byTag.set(r.tag, { severity: r.severity, reason: r.reason, items: [] });
      byTag.get(r.tag).items.push(f);
    }
  }
  const groups = [...byTag.entries()]
    .map(([tag, g]) => ({ tag, ...g }))
    .sort((a, b) => severityRank(a.severity) - severityRank(b.severity));

  return {
    sections: filtered.map((s) => ({ key: s.key, title: s.title, type: s.type })),
    totalScanned,
    totalItems,
    itemErrors,
    sectionErrors,
    findings,
    groups,
  };
}
