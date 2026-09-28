#!/usr/bin/env node
// Minimal App Store Connect client for the release flow.
//
//   node scripts/asc.mjs status                 # versions + recent builds
//   node scripts/asc.mjs await-build 29         # wait for a build to finish processing
//   node scripts/asc.mjs release 1.0.14 29 notes.txt
//        creates the version if missing, sets the release notes for every
//        localisation it has, and attaches the build. Never submits for review:
//        that stays a human decision.
//
// Signs an ES256 JWT with the .p8 in ~/.appstoreconnect. The key never leaves
// that directory and is never printed. Key id and issuer id are identifiers,
// not secrets, and match scripts/release-tvos.sh.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const KEY_ID = "2Y8K8NTUV3";
const ISSUER = "e9e9d3ec-0c04-4694-bcb9-55e8407672f6";
const APP_ID = "6762563534";
const KEY_PATH = path.join(os.homedir(), ".appstoreconnect", `AuthKey_${KEY_ID}.p8`);

function token() {
  const now = Math.floor(Date.now() / 1000);
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = b64({ alg: "ES256", kid: KEY_ID, typ: "JWT" });
  // aud is fixed by Apple; 20 minutes is the maximum they accept.
  const body = b64({ iss: ISSUER, iat: now, exp: now + 1200, aud: "appstoreconnect-v1" });
  const input = `${head}.${body}`;
  // JWT needs raw r||s, not DER, hence ieee-p1363.
  const sig = crypto.sign("sha256", Buffer.from(input), {
    key: fs.readFileSync(KEY_PATH),
    dsaEncoding: "ieee-p1363",
  });
  return `${input}.${sig.toString("base64url")}`;
}

export async function req(method, endpoint, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com/v1/${endpoint}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`HTTP ${res.status} ${method} ${endpoint}: ${text.slice(0, 600)}`);
  return text ? JSON.parse(text) : null;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function findBuild(version) {
  const b = await req("GET", `builds?filter[app]=${APP_ID}&limit=10&sort=-version`);
  return b.data.find((x) => x.attributes.version === String(version));
}

async function awaitBuild(version, { tries = 30, waitMs = 30_000 } = {}) {
  for (let i = 1; i <= tries; i++) {
    const build = await findBuild(version);
    if (build) {
      const state = build.attributes.processingState;
      console.log(`build ${version}: ${state}`);
      if (state === "VALID") return build;
      if (state !== "PROCESSING") throw new Error(`build ${version} is ${state}`);
    } else {
      console.log(`build ${version}: not visible yet (${i}/${tries})`);
    }
    await sleep(waitMs);
  }
  throw new Error(`timed out waiting for build ${version}`);
}

async function status() {
  const vers = await req("GET", `apps/${APP_ID}/appStoreVersions?limit=5`);
  console.log("versions:");
  for (const v of vers.data) console.log(`  ${v.attributes.versionString.padEnd(8)} ${v.attributes.appStoreState}`);
  const builds = await req("GET", `builds?filter[app]=${APP_ID}&limit=5&sort=-version`);
  console.log("builds:");
  for (const b of builds.data) console.log(`  ${b.attributes.version.padEnd(4)} ${b.attributes.processingState}  uploaded ${b.attributes.uploadedDate}`);
}

async function release(versionString, buildVersion, notesPath) {
  const notes = fs.readFileSync(notesPath, "utf8").trim();
  const build = await awaitBuild(buildVersion);

  const existing = await req("GET", `apps/${APP_ID}/appStoreVersions?limit=10`);
  let version = existing.data.find((v) => v.attributes.versionString === versionString);
  if (version) {
    console.log(`version ${versionString} exists (${version.attributes.appStoreState})`);
  } else {
    const created = await req("POST", "appStoreVersions", {
      data: {
        type: "appStoreVersions",
        attributes: { platform: "TV_OS", versionString },
        relationships: { app: { data: { type: "apps", id: APP_ID } } },
      },
    });
    version = created.data;
    console.log(`created version ${versionString}`);
  }

  // App Store Connect copies localisations forward from the previous version, so
  // patch whatever is there rather than assuming a locale.
  const locs = await req("GET", `appStoreVersions/${version.id}/appStoreVersionLocalizations`);
  for (const loc of locs.data) {
    await req("PATCH", `appStoreVersionLocalizations/${loc.id}`, {
      data: { type: "appStoreVersionLocalizations", id: loc.id, attributes: { whatsNew: notes } },
    });
    console.log(`  notes set for ${loc.attributes.locale}`);
  }

  await req("PATCH", `appStoreVersions/${version.id}/relationships/build`, {
    data: { type: "builds", id: build.id },
  });
  console.log(`attached build ${buildVersion} to ${versionString}`);
  console.log("\nReady to submit for review in App Store Connect.");
}

const [cmd, ...args] = process.argv.slice(2);
try {
  if (cmd === "status") await status();
  else if (cmd === "await-build") await awaitBuild(args[0]);
  else if (cmd === "release") await release(args[0], args[1], args[2]);
  else {
    console.error("usage: asc.mjs status | await-build <build> | release <version> <build> <notes.txt>");
    process.exit(2);
  }
} catch (e) {
  console.error("Error:", e.message);
  process.exit(1);
}
