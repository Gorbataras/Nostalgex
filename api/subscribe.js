/** Same handler as `projects/sonoshaus-site/api/subscribe.js` — Resend contacts + optional segment. */
export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { email } = req.body || {};

  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return res.status(400).json({ error: 'Valid email required' });
  }

  const apiKey = process.env.RESEND_API_KEY;
  // RESEND_AUDIENCE_ID is the canonical name; RESEND_SEGMENT_ID kept as legacy alias
  const audienceId = process.env.RESEND_AUDIENCE_ID || process.env.RESEND_SEGMENT_ID;

  if (!apiKey || !audienceId) {
    return res.status(500).json({ error: 'Server misconfigured' });
  }

  try {
    const body = { email };

    const response = await fetch(`https://api.resend.com/audiences/${audienceId}/contacts`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    });

    // 409 = duplicate contact, treat as success
    if (response.ok || response.status === 409) {
      return res.status(200).json({ ok: true });
    }

    const data = await response.json().catch(() => ({}));
    return res.status(response.status).json({ error: data.message || 'Subscription failed' });
  } catch {
    return res.status(500).json({ error: 'Subscription failed' });
  }
}
