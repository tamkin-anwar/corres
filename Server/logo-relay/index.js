// Company logos for Corres, the private way. The app sends a sender's
// domain (never an address, a subject or anything from an email); this
// looks up the brand mark the company publishes for email (BIMI), and
// only one that comes with a mark certificate (VMC or CMC), the same proof
// Gmail asks for before it shows one, so a lookalike domain can't borrow a
// real brand's logo. The mark is drawn to a small PNG and sent back. The
// company's server sees this function, never the person reading.
//
// Nothing is logged or stored but an in-memory cache of logos by domain.
const functions = require('@google-cloud/functions-framework');
const dns = require('dns').promises;
const net = require('net');
const { Resvg } = require('@resvg/resvg-js');

const SIDE = 160;
const MAX_SVG = 64 * 1024;
const cache = new Map(); // domain -> { at, png|null }
const DAY = 24 * 60 * 60 * 1000;

const DOMAIN = /^(?=.{3,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;
// Two-part endings, for the organizational domain (mail.example.co.uk → example.co.uk).
const SECOND_LEVEL = new Set(['co', 'com', 'org', 'net', 'ac', 'gov', 'edu', 'ne', 'or']);

function organizational(domain) {
  const labels = domain.split('.');
  if (labels.length <= 2) return domain;
  const keep = labels.length >= 3 && labels[labels.length - 1].length === 2 && SECOND_LEVEL.has(labels[labels.length - 2]) ? 3 : 2;
  return labels.slice(-keep).join('.');
}

// v=BIMI1; l=https://…/logo.svg; a=https://…/vmc.pem
function parseBIMI(record) {
  const tags = {};
  for (const part of record.split(';')) {
    const at = part.indexOf('=');
    if (at > 0) tags[part.slice(0, at).trim().toLowerCase()] = part.slice(at + 1).trim();
  }
  if ((tags.v || '').toUpperCase() !== 'BIMI1') return null;
  return { logo: tags.l || '', evidence: tags.a || '' };
}

async function lookup(domain) {
  for (const name of [domain, organizational(domain)]) {
    try {
      const records = await dns.resolveTxt(`default._bimi.${name}`);
      for (const chunks of records) {
        const bimi = parseBIMI(chunks.join(''));
        if (bimi) return bimi;
      }
    } catch (_) { /* no record here; try the organizational domain */ }
    if (name === organizational(domain)) break;
  }
  return null;
}

function isPrivate(address) {
  if (net.isIPv4(address)) {
    const [a, b] = address.split('.').map(Number);
    return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31)
      || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224;
  }
  const lower = address.toLowerCase();
  return lower === '::1' || lower.startsWith('fc') || lower.startsWith('fd') || lower.startsWith('fe80') || lower.startsWith('::ffff:');
}

// Only a public https address, and only an SVG small enough to be a logo.
async function fetchSVG(url) {
  let parsed;
  try { parsed = new URL(url); } catch (_) { return null; }
  if (parsed.protocol !== 'https:') return null;
  const addresses = await dns.lookup(parsed.hostname, { all: true }).catch(() => []);
  if (!addresses.length || addresses.some(({ address }) => isPrivate(address))) return null;
  const response = await fetch(parsed, { redirect: 'error', signal: AbortSignal.timeout(4000) }).catch(() => null);
  if (!response || !response.ok) return null;
  const length = Number(response.headers.get('content-length') || 0);
  if (length > MAX_SVG) return null;
  const text = await response.text().catch(() => '');
  if (!text || text.length > MAX_SVG || !/<svg[\s>]/i.test(text)) return null;
  // SVG Tiny PS has no scripts or external references; refuse any that do.
  if (/<script|<foreignObject|xlink:href\s*=\s*["']https?:|href\s*=\s*["']https?:/i.test(text)) return null;
  return text;
}

function render(svg) {
  try {
    const resvg = new Resvg(svg, { fitTo: { mode: 'width', value: SIDE }, background: 'rgba(255,255,255,1)' });
    return resvg.render().asPng();
  } catch (_) {
    return null;
  }
}

async function logoFor(domain) {
  const hit = cache.get(domain);
  if (hit && Date.now() - hit.at < (hit.png ? 7 * DAY : DAY)) return hit.png;
  let png = null;
  const bimi = await lookup(domain);
  // A certificate, as Gmail requires: without one, any domain could show
  // any logo, including a bank's on a lookalike.
  if (bimi && bimi.logo && bimi.evidence) {
    const svg = await fetchSVG(bimi.logo);
    if (svg) png = render(svg);
  }
  if (cache.size > 5000) cache.clear();
  cache.set(domain, { at: Date.now(), png });
  return png;
}

functions.http('corresLogos', async (req, res) => {
  res.set('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).end();
  const domain = String((req.body && req.body.domain) || '').trim().toLowerCase();
  if (!DOMAIN.test(domain)) return res.status(400).end();
  const png = await logoFor(domain);
  if (!png) return res.status(404).end();
  res.set('Content-Type', 'image/png');
  res.status(200).send(png);
});

module.exports = { parseBIMI, organizational, isPrivate };
