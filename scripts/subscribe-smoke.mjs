#!/usr/bin/env node
/**
 * Smoke test for api/subscribe.js. Stubs fetch, so nothing reaches Resend.
 * Run: `npm run test:subscribe`.
 */
import handler, { signupProperties } from "../api/subscribe.js";

let pass = 0;
const failures = [];
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) pass++;
  else failures.push(`${name}: expected ${e}, got ${a}`);
}

/** Queue of canned Resend responses; records every request. */
function stubResend(responses) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({
      url: String(url).replace("https://api.resend.com", ""),
      method: init.method,
      body: init.body ? JSON.parse(init.body) : undefined,
    });
    const next = responses.shift() || { status: 200, body: {} };
    return {
      status: next.status,
      ok: next.status >= 200 && next.status < 300,
      json: async () => next.body || {},
    };
  };
  return calls;
}

async function call(body, method = "POST") {
  let status = 0;
  let json = null;
  const res = {
    status(code) { status = code; return this; },
    json(data) { json = data; return this; },
  };
  await handler({ method, body }, res);
  return { status, json };
}

process.env.RESEND_API_KEY = "test_key";
process.env.RESEND_AUDIENCE_ID = "seg_test";
delete process.env.RESEND_SEGMENT_ID;

// ---- Whitelisting ----
check("qr settings props", signupProperties({
  source: "appletv_qr_settings",
  page: "/",
  utm: { source: "appletv", medium: "app", campaign: "qr_signup", content: "settings" },
}), {
  signup_source: "appletv_qr_settings",
  signup_page: "/",
  utm_source: "appletv",
  utm_medium: "app",
  utm_campaign: "qr_signup",
  utm_content: "settings",
});
check("uppercase is normalized", signupProperties({ source: "Home_CTA" }), { signup_source: "home_cta" });
check("junk is dropped", signupProperties({
  source: "<script>",
  page: "https://evil.example/x",
  utm: { source: "a b", medium: "x".repeat(41), campaign: 5, content: null, extra: "nope" },
  ip: "1.2.3.4",
}), {});
check("old client pathname source dropped", signupProperties({ source: "/web-tuner" }), {});
check("page path kept", signupProperties({ page: "/web-tuner" }), { signup_page: "/web-tuner" });
check("utm not an object", signupProperties({ utm: "appletv" }), {});

// ---- Handler ----
{
  const calls = stubResend([]);
  const r = await call({ email: "nope" });
  check("invalid email 400", r.status, 400);
  check("invalid email no network", calls.length, 0);
}
{
  const calls = stubResend([]);
  const r = await call({ email: "a@b.co" }, "GET");
  check("GET 405", r.status, 405);
  check("GET no network", calls.length, 0);
}
{
  delete process.env.RESEND_API_KEY;
  const r = await call({ email: "a@b.co" });
  check("missing env 500", r.status, 500);
  process.env.RESEND_API_KEY = "test_key";
}
{
  const calls = stubResend([{ status: 200, body: { object: "contact", id: "c1" } }]);
  const r = await call({
    email: " fan@example.com ",
    source: "appletv_qr_settings",
    page: "/",
    utm: { source: "appletv", medium: "app", campaign: "qr_signup", content: "settings" },
  });
  check("create ok", r.status, 200);
  check("create one call", calls.length, 1);
  check("create endpoint", `${calls[0].method} ${calls[0].url}`, "POST /contacts");
  check("create body", calls[0].body, {
    email: "fan@example.com",
    unsubscribed: false,
    segments: [{ id: "seg_test" }],
    properties: {
      signup_source: "appletv_qr_settings",
      signup_page: "/",
      utm_source: "appletv",
      utm_medium: "app",
      utm_campaign: "qr_signup",
      utm_content: "settings",
    },
  });
}
{
  const calls = stubResend([{ status: 200, body: {} }]);
  await call({ email: "plain@example.com" });
  check("no props key when nothing valid", "properties" in calls[0].body, false);
}
{
  // Properties not created in Resend yet: retry without them so the signup lands.
  const calls = stubResend([
    { status: 422, body: { name: "validation_error", message: "Property signup_source does not exist" } },
    { status: 200, body: { id: "c2" } },
  ]);
  const r = await call({ email: "early@example.com", source: "home_cta" });
  check("missing props retry ok", r.status, 200);
  check("missing props retried", calls.length, 2);
  check("retry drops properties", "properties" in calls[1].body, false);
  check("retry keeps segment", calls[1].body.segments, [{ id: "seg_test" }]);
}
{
  // Duplicate with no source yet: add to segment, then first-touch fill.
  const calls = stubResend([
    { status: 409, body: { message: "Contact already exists" } },
    { status: 200, body: { id: "seg_test" } },
    { status: 200, body: { email: "dup@example.com", properties: {} } },
    { status: 200, body: {} },
  ]);
  const r = await call({ email: "dup@example.com", source: "webtuner", page: "/web-tuner" });
  check("dup ok", r.status, 200);
  check("dup call sequence", calls.map((c) => `${c.method} ${c.url}`), [
    "POST /contacts",
    "POST /contacts/dup%40example.com/segments/seg_test",
    "GET /contacts/dup%40example.com",
    "PATCH /contacts/dup%40example.com",
  ]);
  check("dup patch body", calls[3].body, { properties: { signup_source: "webtuner", signup_page: "/web-tuner" } });
}
{
  // Duplicate that already has a source: never overwrite it.
  const calls = stubResend([
    { status: 409, body: {} },
    { status: 200, body: {} },
    { status: 200, body: { properties: { signup_source: { value: "home_cta", type: "string" } } } },
  ]);
  const r = await call({ email: "dup2@example.com", source: "footer_support" });
  check("dup keep ok", r.status, 200);
  check("dup keep no patch", calls.some((c) => c.method === "PATCH"), false);
}
{
  // Duplicate reported as a 422 "already exists" is still success.
  stubResend([{ status: 422, body: { message: "Contact already exists" } }, { status: 200 }, { status: 200, body: {} }]);
  const r = await call({ email: "dup3@example.com" });
  check("dup 422 ok", r.status, 200);
}
{
  // A duplicate never flips unsubscribed or re-sends consent.
  const calls = stubResend([{ status: 409 }, { status: 200 }, { status: 200, body: {} }, { status: 200 }]);
  await call({ email: "dup4@example.com", source: "home_cta" });
  check("dup never touches unsubscribed", calls.slice(1).some((c) => c.body && "unsubscribed" in c.body), false);
}
{
  stubResend([{ status: 500, body: { message: "boom" } }]);
  const r = await call({ email: "err@example.com" });
  check("upstream 500 surfaces", r.status, 500);
}
{
  globalThis.fetch = async () => { throw new Error("network down"); };
  const r = await call({ email: "net@example.com" });
  check("network error 500", r.status, 500);
}

if (failures.length) {
  console.error(`subscribe smoke: ${failures.length} failed, ${pass} passed`);
  for (const f of failures) console.error("  - " + f);
  process.exit(1);
}
console.log(`subscribe smoke: ${pass} passed`);
