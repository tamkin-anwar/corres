// Company logos for Corres, the private way. The app sends a sender's
// domain (never an address, a subject or anything from an email); this
// looks up the brand mark the company publishes for email (BIMI), and
// only one that comes with a valid mark certificate (VMC or CMC), the same
// proof Gmail asks for before it shows one, so a lookalike domain can't
// borrow a real brand's logo. The certificate is checked here (vmc.js):
// its chain to a mark certificate root, that it's for this domain, and
// the logo inside it, which is the one drawn. The mark is drawn to a small
// PNG and sent back. The company's server sees this function, never the
// person reading.
//
// Nothing is logged or stored but an in-memory cache of logos by domain
// (the 5,000 most recently asked for) and, for a minute, how many calls
// each caller's address made (the rate limit below).
const functions = require('@google-cloud/functions-framework');
const dns = require('dns');
const https = require('https');
const net = require('net');
const { Resvg } = require('@resvg/resvg-js');
const vmc = require('./vmc');

const SIDE = 160;
const MAX_SVG = 64 * 1024;
// A mark certificate file: the certificate (with its logo inside) and its
// intermediates. The largest seen is under 20 KB.
const MAX_PEM = 128 * 1024;
const FETCH_TIMEOUT_MS = 4000;
// Least recently used first: a Map keeps insertion order, and a domain
// asked for again is moved to the end, so the one dropped when it's full
// is the one nobody has asked for the longest.
const cache = new Map(); // domain -> { at, png|null }
const CACHE_SIZE = 5000;
const inflight = new Map(); // domain -> Promise<png|null>
const DAY = 24 * 60 * 60 * 1000;

function cached(domain) {
  const hit = cache.get(domain);
  if (!hit) return null;
  cache.delete(domain);
  cache.set(domain, hit);
  return hit;
}

function remember(domain, png) {
  cache.delete(domain);
  cache.set(domain, { at: Date.now(), png });
  while (cache.size > CACHE_SIZE) cache.delete(cache.keys().next().value);
}

// ---- Best-effort rate limit ------------------------------------------------
// In memory, per instance: a brake on one busy caller, as the push relay
// has. A new install asks for every sender's logo once, a few at a time,
// so 120 a minute is far above a person's use; past it the app gets 429
// and simply asks again later (it only remembers a 404 as "no logo"). The
// caller's address is the last X-Forwarded-For entry, the one Google's
// front end adds. Nothing is kept beyond the minute.
const RATE_LIMIT = 120;
const RATE_WINDOW_MS = 60_000;
const rateWindows = new Map(); // ip -> { start, count }

function clientIP(req) {
  const forwarded = String(req.get('x-forwarded-for') || '').split(',').map((s) => s.trim()).filter(Boolean);
  return forwarded.length ? forwarded[forwarded.length - 1] : (req.ip || 'unknown');
}

function rateLimited(req, now = Date.now()) {
  if (rateWindows.size > 20_000) {
    for (const [key, window] of rateWindows) if (now - window.start >= RATE_WINDOW_MS) rateWindows.delete(key);
    if (rateWindows.size > 20_000) rateWindows.clear();
  }
  const ip = clientIP(req);
  let window = rateWindows.get(ip);
  if (!window || now - window.start >= RATE_WINDOW_MS) {
    window = { start: now, count: 0 };
    rateWindows.set(ip, window);
  }
  window.count += 1;
  return window.count > RATE_LIMIT;
}

const resolver = new dns.promises.Resolver({ timeout: 2000, tries: 2 });

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

async function txt(name) {
  try {
    return (await resolver.resolveTxt(name)).map((chunks) => chunks.join(''));
  } catch (_) {
    return [];
  }
}

// The record and the domain it was found at.
async function lookup(domain) {
  for (const name of [domain, organizational(domain)]) {
    for (const record of await txt(`default._bimi.${name}`)) {
      const bimi = parseBIMI(record);
      if (bimi) return { ...bimi, at: name };
    }
    if (name === organizational(domain)) break;
  }
  return null;
}

async function dmarcRecord(name) {
  return (await txt(`_dmarc.${name}`)).find((r) => vmc.parseDMARC(r)) || null;
}

async function dmarcEnforced(domain) {
  const org = organizational(domain);
  const [own, orgRecord] = await Promise.all([domain === org ? null : dmarcRecord(domain), dmarcRecord(org)]);
  return vmc.dmarcEnforced(own, orgRecord, domain !== org);
}

function isPrivate(address) {
  if (net.isIPv4(address)) {
    const [a, b] = address.split('.').map(Number);
    return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31)
      || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || (a === 198 && (b === 18 || b === 19)) || a >= 224;
  }
  const lower = address.toLowerCase();
  return lower === '::' || lower === '::1' || lower.startsWith('fc') || lower.startsWith('fd') || lower.startsWith('fe80')
    || lower.startsWith('::ffff:') || lower.startsWith('64:ff9b:') || lower.startsWith('2002:') || lower.startsWith('ff');
}

// The address the connection uses is the one checked here: the socket
// connects to exactly what this returns, so a name that answers a public
// address to a first lookup and a private one to a second can't slip in.
function publicLookup(hostname, options, callback) {
  dns.lookup(hostname, { all: true }, (error, addresses) => {
    if (error) return callback(error);
    if (!addresses.length || addresses.some(({ address }) => isPrivate(address))) {
      return callback(Object.assign(new Error('private address'), { code: 'EPRIVATE' }));
    }
    if (options && options.all) return callback(null, addresses);
    callback(null, addresses[0].address, addresses[0].family);
  });
}

// One https GET to a public address, no redirects, within the size and
// time limits. Null on anything else.
function fetchPublic(url, maxBytes) {
  let parsed;
  try { parsed = new URL(url); } catch (_) { return Promise.resolve(null); }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password) return Promise.resolve(null);
  if (net.isIP(parsed.hostname.replace(/^\[|\]$/g, ''))) return Promise.resolve(null);
  return new Promise((resolve) => {
    let settled = false;
    const done = (value) => { if (!settled) { settled = true; clearTimeout(timer); resolve(value); } };
    const request = https.get(parsed, { lookup: publicLookup, headers: { accept: '*/*' } }, (response) => {
      if (response.statusCode !== 200 || Number(response.headers['content-length'] || 0) > maxBytes) {
        response.resume();
        request.destroy();
        return done(null);
      }
      const chunks = [];
      let size = 0;
      response.on('data', (chunk) => {
        size += chunk.length;
        if (size > maxBytes) { request.destroy(); return done(null); }
        chunks.push(chunk);
      });
      response.on('end', () => done(Buffer.concat(chunks).toString('utf8')));
      response.on('error', () => done(null));
    });
    request.on('error', () => done(null));
    const timer = setTimeout(() => { request.destroy(); done(null); }, FETCH_TIMEOUT_MS);
  });
}

// SVG Tiny PS has no scripts and no outside references: only links to
// its own elements ("#id") are allowed, and no entities.
function safeSVG(text) {
  if (!text || text.length > MAX_SVG || !/<svg[\s>]/i.test(text)) return false;
  if (/<script|<foreignObject|<!ENTITY|<!DOCTYPE[^>]*\[/i.test(text)) return false;
  if (/href\s*=\s*["']\s*(?!#)/i.test(text)) return false;
  if (/url\(\s*["']?\s*(?!#)/i.test(text) || /@import/i.test(text)) return false;
  return true;
}

function render(svg) {
  try {
    const resvg = new Resvg(svg, { fitTo: { mode: 'width', value: SIDE }, background: 'rgba(255,255,255,1)' });
    return resvg.render().asPng();
  } catch (_) {
    return null;
  }
}

async function findLogo(domain) {
  const bimi = await lookup(domain);
  // A certificate, as Gmail requires: without one, any domain could show
  // any logo, including a bank's on a lookalike.
  if (!bimi || !bimi.logo || !bimi.evidence) return null;
  const [pem, enforced] = await Promise.all([fetchPublic(bimi.evidence, MAX_PEM), dmarcEnforced(domain)]);
  if (!pem || !enforced) return null;
  let svg;
  try {
    svg = vmc.verifiedMark(pem, [domain, bimi.at, organizational(domain)]);
  } catch (_) {
    return null;
  }
  return safeSVG(svg) ? render(svg) : null;
}

async function logoFor(domain) {
  const hit = cached(domain);
  if (hit && Date.now() - hit.at < (hit.png ? 7 * DAY : DAY)) return hit.png;
  // Many people opening the same company's mail at once share one lookup.
  if (inflight.has(domain)) return inflight.get(domain);
  const work = findLogo(domain).catch(() => null).then((png) => {
    remember(domain, png);
    return png;
  }).finally(() => inflight.delete(domain));
  inflight.set(domain, work);
  return work;
}

functions.http('corresLogos', async (req, res) => {
  res.set('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).end();
  if (rateLimited(req)) return res.status(429).set('Retry-After', '60').end();
  const raw = req.body && req.body.domain;
  if (typeof raw !== 'string') return res.status(400).end();
  const domain = raw.trim().toLowerCase();
  if (!DOMAIN.test(domain)) return res.status(400).end();
  const png = await logoFor(domain);
  if (!png) return res.status(404).end();
  res.set('Content-Type', 'image/png');
  res.status(200).send(png);
});

module.exports = { parseBIMI, organizational, isPrivate, safeSVG, publicLookup, fetchPublic, logoFor, rateLimited, cache, remember, cached };
