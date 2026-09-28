/**
 * Email signup → Resend contact in the Nostalgex segment.
 *
 * Records where the signup came from (form or Apple TV QR) as contact properties,
 * first touch only. Every property is whitelisted here; anything that doesn't match
 * is dropped, never stored. No IP, no user agent, nothing else about the visitor.
 *
 * Properties must exist in Resend (Contacts → Properties) before contacts can carry
 * them: signup_source, signup_page, utm_source, utm_medium, utm_campaign, utm_content.
 * Until they do, a signup still goes through without properties (see the retry below).
 */

const RESEND = 'https://api.resend.com';
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const TOKEN_RE = /^[a-z0-9_]{1,40}$/;
const PAGE_RE = /^\/[a-z0-9_/-]{0,59}$/;
const UTM_KEYS = ['source', 'medium', 'campaign', 'content'];

function token(value) {
  if (typeof value !== 'string') return undefined;
  const v = value.trim().toLowerCase();
  return TOKEN_RE.test(v) ? v : undefined;
}

function page(value) {
  if (typeof value !== 'string') return undefined;
  const v = value.trim().toLowerCase();
  return PAGE_RE.test(v) ? v : undefined;
}

/** Whitelisted contact properties from a request body. Exported for the smoke test. */
export function signupProperties(body) {
  const props = {};
  const source = token(body.source);
  if (source) props.signup_source = source;
  const signupPage = page(body.page);
  if (signupPage) props.signup_page = signupPage;
  const utm = body.utm && typeof body.utm === 'object' ? body.utm : {};
  for (const key of UTM_KEYS) {
    const v = token(utm[key]);
    if (v) props[`utm_${key}`] = v;
  }
  return props;
}

async function resend(apiKey, method, path, body) {
  const res = await fetch(`${RESEND}${path}`, {
    method,
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  return { status: res.status, ok: res.ok, data };
}

function isDuplicate(result) {
  if (result.status === 409) return true;
  const text = `${result.data?.name || ''} ${result.data?.message || ''}`.toLowerCase();
  return result.status === 422 && text.includes('already exists');
}

/** Existing contact: make sure they're in the segment, and fill the source only if empty. */
async function handleExisting(apiKey, email, segmentId, props) {
  const encoded = encodeURIComponent(email);
  // Idempotent. A contact who signed up for another list on this Resend account
  // still has to land in the Nostalgex segment.
  await resend(apiKey, 'POST', `/contacts/${encoded}/segments/${segmentId}`);

  if (!props.signup_source) return;
  const existing = await resend(apiKey, 'GET', `/contacts/${encoded}`);
  if (!existing.ok) return;
  const current = existing.data?.properties?.signup_source;
  const currentValue = current && typeof current === 'object' ? current.value : current;
  if (currentValue) return; // first touch wins
  await resend(apiKey, 'PATCH', `/contacts/${encoded}`, { properties: props });
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const body = req.body && typeof req.body === 'object' ? req.body : {};
  const email = typeof body.email === 'string' ? body.email.trim() : '';

  if (!email || email.length > 254 || !EMAIL_RE.test(email)) {
    return res.status(400).json({ error: 'Valid email required' });
  }

  const apiKey = process.env.RESEND_API_KEY;
  // RESEND_AUDIENCE_ID is the canonical name; RESEND_SEGMENT_ID kept as an alias.
  // Resend kept audience ids when audiences became segments, so either works.
  const segmentId = process.env.RESEND_AUDIENCE_ID || process.env.RESEND_SEGMENT_ID;

  if (!apiKey || !segmentId) {
    return res.status(500).json({ error: 'Server misconfigured' });
  }

  const props = signupProperties(body);

  try {
    const payload = { email, unsubscribed: false, segments: [{ id: segmentId }] };
    if (Object.keys(props).length) payload.properties = props;

    let created = await resend(apiKey, 'POST', '/contacts', payload);

    // Properties not defined in Resend yet (or renamed): never lose the signup over them.
    if (!created.ok && !isDuplicate(created) && payload.properties && created.status >= 400 && created.status < 500) {
      delete payload.properties;
      created = await resend(apiKey, 'POST', '/contacts', payload);
    }

    if (created.ok) {
      return res.status(200).json({ ok: true });
    }

    if (isDuplicate(created)) {
      await handleExisting(apiKey, email, segmentId, props).catch(() => {});
      return res.status(200).json({ ok: true });
    }

    return res.status(created.status || 500).json({ error: created.data?.message || 'Subscription failed' });
  } catch {
    return res.status(500).json({ error: 'Subscription failed' });
  }
}
