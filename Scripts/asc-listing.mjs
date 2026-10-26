#!/usr/bin/env node
// The App Store listing, from the repo into App Store Connect, with the
// API key from Docs/asc-api-key.md (~/.corres/asc.env). Never prints the key.
//
//   node Scripts/asc-listing.mjs status        what's in App Store Connect now (read-only)
//   node Scripts/asc-listing.mjs apply         descriptions, keywords, promo text, subtitles
//   node Scripts/asc-listing.mjs diff [locale] what apply would change, line by line (read-only)
//   node Scripts/asc-listing.mjs watch-shots   Apple Watch screenshots (Docs/AppStore/watch)
//   node Scripts/asc-listing.mjs shots         every locale's screenshot sets and files (read-only)
//   node Scripts/asc-listing.mjs replace-shots <locale> <display type> <png>...
//                                              uploads these, in this order, and removes the set's
//                                              old ones once the new ones are in (a full set is
//                                              swapped one at a time to stay within Apple's 10)
//
// Sources: English from Docs/app-store-listing.md, every other language
// from Docs/AppStore/localized/listing.json (rebuild it with listing.py).
// Only versions that can still be edited are touched; nothing is submitted.

import { readFileSync, readdirSync, statSync } from 'node:fs'
import { createHash, createPrivateKey, sign } from 'node:crypto'
import { homedir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const bundleId = 'studio.anwarcreative.corres'
const editable = new Set(['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY'])

// MARK: Key and requests

function env() {
  const out = { ...process.env }
  const file = process.env.ASC_ENV_FILE ?? join(homedir(), '.corres', 'asc.env')
  try {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const m = line.match(/^\s*(?:export\s+)?(ASC_[A-Z_]+)=["']?([^"'\n]*)["']?\s*$/)
      if (m && !out[m[1]]) out[m[1]] = m[2]
    }
  } catch {}
  for (const k of ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_PATH'])
    if (!out[k]) throw new Error(`Missing ${k}: see Docs/asc-api-key.md`)
  out.ASC_KEY_PATH = out.ASC_KEY_PATH.replace(/^~/, homedir())
  return out
}

const e = env()
const key = createPrivateKey(readFileSync(e.ASC_KEY_PATH))
function token() {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
  const now = Math.floor(Date.now() / 1000)
  const body = `${b64({ alg: 'ES256', kid: e.ASC_KEY_ID, typ: 'JWT' })}.${b64({ iss: e.ASC_ISSUER_ID, iat: now, exp: now + 15 * 60, aud: 'appstoreconnect-v1' })}`
  return `${body}.${sign('sha256', Buffer.from(body), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`
}

async function api(method, path, body) {
  const res = await fetch(path.startsWith('http') ? path : `https://api.appstoreconnect.apple.com${path}`, {
    method, headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await res.text()
  const json = text ? JSON.parse(text) : {}
  if (!res.ok) {
    const why = (json.errors ?? []).map((x) => `${x.title}: ${x.detail}`).join('; ')
    throw new Error(`${method} ${path} → ${res.status} ${why}`)
  }
  return json
}

async function all(path) {
  const out = []
  for (let next = path; next; ) {
    const page = await api('GET', next)
    out.push(...page.data)
    next = page.links?.next
  }
  return out
}

// MARK: The listing in the repo

function english() {
  const md = readFileSync(join(root, 'Docs/app-store-listing.md'), 'utf8')
  const quote = (from, to) => {
    const part = md.slice(md.indexOf(from), to ? md.indexOf(to, md.indexOf(from)) : undefined)
    return part.split('\n').filter((l) => l.startsWith('>')).map((l) => l.replace(/^> ?/, '')).join('\n').trim()
  }
  const promo = md.slice(md.indexOf('## Promotional text'), md.indexOf('## Description'))
  const keywords = md.slice(md.indexOf('## Keywords')).match(/```\n([^\n]+)\n```/)[1]
  return {
    subtitle: md.match(/\| Subtitle \(30\) \| \*\*(.+?)\*\*/)[1],
    keywords,
    ios: { description: quote('### iOS', '### macOS'), promotionalText: quote('iOS:', 'macOS:').split('\n')[0] },
    mac: { description: quote('### macOS', '## Keywords'), promotionalText: promo.slice(promo.indexOf('macOS:')).split('\n').find((l) => l.startsWith('>')).replace(/^> ?/, '') },
  }
}

function listing() {
  const out = JSON.parse(readFileSync(join(root, 'Docs/AppStore/localized/listing.json'), 'utf8'))
  out['en-US'] = english()
  for (const [loc, l] of Object.entries(out)) {
    if (l.subtitle.length > 30 || l.keywords.length > 100) throw new Error(`${loc}: subtitle or keywords too long`)
    for (const p of ['ios', 'mac'])
      if (l[p].description.length > 4000 || l[p].promotionalText.length > 170) throw new Error(`${loc} ${p}: over Apple's limits`)
  }
  return out
}

// MARK: App Store Connect

async function app() {
  const [a] = await all(`/v1/apps?filter[bundleId]=${bundleId}`)
  if (!a) throw new Error(`No app with bundle ID ${bundleId}`)
  return a
}

async function versions(appId) {
  const vs = await all(`/v1/apps/${appId}/appStoreVersions?limit=50`)
  return vs.map((v) => ({ id: v.id, platform: v.attributes.platform, version: v.attributes.versionString, state: v.attributes.appVersionState ?? v.attributes.appStoreState }))
}

async function status() {
  const a = await app()
  console.log(`${a.attributes.name} (${a.id}), primary language ${a.attributes.primaryLocale}`)
  for (const v of await versions(a.id)) {
    const locs = await all(`/v1/appStoreVersions/${v.id}/appStoreVersionLocalizations?limit=50`)
    console.log(`\n${v.platform} ${v.version}: ${v.state}`)
    for (const l of locs) {
      const at = l.attributes
      console.log(`  ${at.locale.padEnd(8)} description ${String(at.description?.length ?? 0).padStart(4)}  keywords ${String(at.keywords?.length ?? 0).padStart(3)}  promo ${String(at.promotionalText?.length ?? 0).padStart(3)}  siri ${/Siri/.test(at.description ?? '') ? 'yes' : 'no'}`)
    }
    if (v.platform === 'IOS') {
      const en = locs.find((l) => l.attributes.locale === a.attributes.primaryLocale)
      if (en) {
        const sets = await all(`/v1/appStoreVersionLocalizations/${en.id}/appScreenshotSets`)
        console.log(`  screenshots (${a.attributes.primaryLocale}): ${sets.map((s) => s.attributes.screenshotDisplayType).join(', ') || 'none'}`)
      }
    }
  }
  for (const info of await all(`/v1/apps/${a.id}/appInfos`)) {
    const locs = await all(`/v1/appInfos/${info.id}/appInfoLocalizations?limit=50`)
    console.log(`\nApp info ${info.attributes.appStoreState ?? info.attributes.state}: ${locs.map((l) => `${l.attributes.locale} "${l.attributes.subtitle ?? ''}"`).join(', ')}`)
  }
  const iaps = await all(`/v1/apps/${a.id}/inAppPurchasesV2?limit=50`).catch((err) => (console.log(`\nIn-app purchases: ${err.message}`), []))
  if (iaps.length) console.log('\nIn-app purchases:')
  for (const p of iaps) console.log(`  ${p.attributes.productId} (${p.attributes.inAppPurchaseType}): ${p.attributes.state}`)
}

async function apply() {
  const want = listing()
  const a = await app()
  const changed = []
  for (const v of await versions(a.id)) {
    if (!editable.has(v.state)) { console.log(`${v.platform} ${v.version}: ${v.state}, left alone`); continue }
    const p = v.platform === 'MAC_OS' ? 'mac' : 'ios'
    const have = Object.fromEntries((await all(`/v1/appStoreVersions/${v.id}/appStoreVersionLocalizations?limit=50`)).map((l) => [l.attributes.locale, l]))
    const primary = have[a.attributes.primaryLocale]?.attributes ?? {}
    for (const [loc, l] of Object.entries(want)) {
      const attrs = { description: l[p].description, keywords: l.keywords, promotionalText: l[p].promotionalText }
      const cur = have[loc]
      if (cur) {
        const diff = Object.fromEntries(Object.entries(attrs).filter(([k, val]) => cur.attributes[k] !== val))
        if (!Object.keys(diff).length) continue
        await api('PATCH', `/v1/appStoreVersionLocalizations/${cur.id}`, { data: { type: 'appStoreVersionLocalizations', id: cur.id, attributes: diff } })
        changed.push(`${v.platform} ${loc}: ${Object.keys(diff).join(', ')}`)
      } else {
        await api('POST', '/v1/appStoreVersionLocalizations', { data: {
          type: 'appStoreVersionLocalizations',
          attributes: { locale: loc, ...attrs, supportUrl: primary.supportUrl, marketingUrl: primary.marketingUrl },
          relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: v.id } } },
        } })
        changed.push(`${v.platform} ${loc}: added`)
      }
    }
  }
  const infos = await all(`/v1/apps/${a.id}/appInfos`)
  const info = infos.find((i) => editable.has(i.attributes.appStoreState ?? i.attributes.state)) ?? infos[0]
  const have = Object.fromEntries((await all(`/v1/appInfos/${info.id}/appInfoLocalizations?limit=50`)).map((l) => [l.attributes.locale, l]))
  const primary = have[a.attributes.primaryLocale]?.attributes ?? {}
  for (const [loc, l] of Object.entries(want)) {
    const cur = have[loc]
    if (cur && cur.attributes.subtitle === l.subtitle) continue
    if (cur) {
      await api('PATCH', `/v1/appInfoLocalizations/${cur.id}`, { data: { type: 'appInfoLocalizations', id: cur.id, attributes: { subtitle: l.subtitle } } })
      changed.push(`app info ${loc}: subtitle`)
    } else {
      await api('POST', '/v1/appInfoLocalizations', { data: {
        type: 'appInfoLocalizations',
        attributes: { locale: loc, name: l.name ?? 'Corres', subtitle: l.subtitle, privacyPolicyUrl: primary.privacyPolicyUrl },
        relationships: { appInfo: { data: { type: 'appInfos', id: info.id } } },
      } })
      changed.push(`app info ${loc}: added`)
    }
  }
  console.log(changed.length ? changed.join('\n') : 'Already up to date.')
}

async function diff() {
  const only = process.argv[3]
  const want = listing()
  const a = await app()
  const lines = (t) => (t ?? '').split('\n')
  for (const v of await versions(a.id)) {
    const p = v.platform === 'MAC_OS' ? 'mac' : 'ios'
    for (const l of await all(`/v1/appStoreVersions/${v.id}/appStoreVersionLocalizations?limit=50`)) {
      const loc = l.attributes.locale
      if ((only && loc !== only) || !want[loc]) continue
      for (const [k, mine] of [['description', want[loc][p].description], ['keywords', want[loc].keywords], ['promotionalText', want[loc][p].promotionalText]]) {
        const theirs = l.attributes[k] ?? ''
        if (theirs === mine) continue
        const a1 = lines(theirs), b1 = lines(mine)
        console.log(`\n${v.platform} ${loc} ${k}:`)
        for (const x of a1) if (!b1.includes(x)) console.log(`  - ${x}`)
        for (const x of b1) if (!a1.includes(x)) console.log(`  + ${x}`)
      }
    }
  }
  const info = (await all(`/v1/apps/${a.id}/appInfos`))[0]
  for (const l of await all(`/v1/appInfos/${info.id}/appInfoLocalizations?limit=50`)) {
    const loc = l.attributes.locale
    if ((only && loc !== only) || !want[loc] || l.attributes.subtitle === want[loc].subtitle) continue
    console.log(`\nsubtitle ${loc}: - ${l.attributes.subtitle}  + ${want[loc].subtitle}`)
  }
}

// Apple Watch Series 10 and later (46 mm): 416 × 496.
async function watchShots() {
  const dir = join(root, 'Docs/AppStore/watch')
  const files = readdirSync(dir).filter((f) => /^watch-\d+\.png$/.test(f)).sort()
  const a = await app()
  const v = (await versions(a.id)).find((x) => x.platform === 'IOS' && editable.has(x.state))
  if (!v) throw new Error('No editable iOS version')
  const loc = (await all(`/v1/appStoreVersions/${v.id}/appStoreVersionLocalizations?limit=50`)).find((l) => l.attributes.locale === a.attributes.primaryLocale)
  const type = 'APP_WATCH_SERIES_10'
  let set = (await all(`/v1/appStoreVersionLocalizations/${loc.id}/appScreenshotSets`)).find((s) => s.attributes.screenshotDisplayType === type)
  if (set) {
    const existing = await all(`/v1/appScreenshotSets/${set.id}/appScreenshots`)
    if (existing.length) { console.log(`${type} already has ${existing.length} screenshots; left alone.`); return }
  } else {
    set = (await api('POST', '/v1/appScreenshotSets', { data: { type: 'appScreenshotSets', attributes: { screenshotDisplayType: type },
      relationships: { appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: loc.id } } } } })).data
  }
  for (const f of files) await uploadShot(set.id, join(dir, f))
}

// One screenshot into a set: reserve, send the parts, then confirm with
// its checksum. Returns the new screenshot's id.
async function uploadShot(setId, path) {
  const name = path.split('/').pop()
  const bytes = readFileSync(path)
  const shot = (await api('POST', '/v1/appScreenshots', { data: { type: 'appScreenshots', attributes: { fileName: name, fileSize: statSync(path).size },
    relationships: { appScreenshotSet: { data: { type: 'appScreenshotSets', id: setId } } } } })).data
  for (const op of shot.attributes.uploadOperations) {
    const res = await fetch(op.url, { method: op.method, headers: Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value])),
      body: bytes.subarray(op.offset, op.offset + op.length) })
    if (!res.ok) throw new Error(`Upload of ${name} failed: ${res.status}`)
  }
  await api('PATCH', `/v1/appScreenshots/${shot.id}`, { data: { type: 'appScreenshots', id: shot.id,
    attributes: { uploaded: true, sourceFileChecksum: createHash('md5').update(bytes).digest('hex') } } })
  console.log(`Uploaded ${name}`)
  return shot.id
}

// Apple processes an upload after it's confirmed; wait until it has.
async function processed(id) {
  for (let i = 0; i < 60; i++) {
    const state = (await api('GET', `/v1/appScreenshots/${id}`)).data.attributes.assetDeliveryState?.state
    if (state === 'COMPLETE') return
    if (state === 'FAILED') throw new Error(`App Store Connect couldn't process screenshot ${id}`)
    await new Promise((r) => setTimeout(r, 3000))
  }
  throw new Error(`Screenshot ${id} still processing after 3 minutes`)
}

// Mac sets live on the macOS version, everything else on iOS.
const platformOf = (type) => (/^APP_DESKTOP/.test(type) ? 'MAC_OS' : 'IOS')

async function localization(a, platform, locale) {
  const v = (await versions(a.id)).find((x) => x.platform === platform && editable.has(x.state))
  if (!v) throw new Error(`No editable ${platform} version`)
  const loc = (await all(`/v1/appStoreVersions/${v.id}/appStoreVersionLocalizations?limit=50`)).find((l) => l.attributes.locale === locale)
  if (!loc) throw new Error(`${platform} ${v.version} has no ${locale} localization`)
  return loc
}

async function shots() {
  const a = await app()
  for (const v of await versions(a.id)) {
    console.log(`\n${v.platform} ${v.version}: ${v.state}`)
    for (const l of await all(`/v1/appStoreVersions/${v.id}/appStoreVersionLocalizations?limit=50`)) {
      for (const s of await all(`/v1/appStoreVersionLocalizations/${l.id}/appScreenshotSets`)) {
        const files = await all(`/v1/appScreenshotSets/${s.id}/appScreenshots`)
        console.log(`  ${l.attributes.locale.padEnd(8)} ${s.attributes.screenshotDisplayType.padEnd(24)} ${files.length}: ${files.map((f) => f.attributes.fileName).join(', ')}`)
      }
    }
  }
}

async function replaceShots() {
  const [locale, type, ...paths] = process.argv.slice(3)
  if (!locale || !type || !paths.length) throw new Error('Usage: replace-shots <locale> <display type> <png>...')
  for (const p of paths) statSync(p)
  const a = await app()
  const loc = await localization(a, platformOf(type), locale)
  let set = (await all(`/v1/appStoreVersionLocalizations/${loc.id}/appScreenshotSets`)).find((s) => s.attributes.screenshotDisplayType === type)
  if (!set) set = (await api('POST', '/v1/appScreenshotSets', { data: { type: 'appScreenshotSets', attributes: { screenshotDisplayType: type },
    relationships: { appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: loc.id } } } } })).data
  const old = (await all(`/v1/appScreenshotSets/${set.id}/appScreenshots`)).map((s) => s.id)
  if (paths.length > 10) throw new Error(`Apple allows 10 screenshots per set, not ${paths.length}`)
  // A set holds at most 10, so a full one is swapped a shot at a time: an
  // old one goes only to make room, and only after every new one so far
  // is uploaded and processed. If an upload fails, the set keeps what it
  // had plus the new ones that made it.
  const left = [...old], added = []
  for (const p of paths) {
    if (left.length + added.length >= 10) await api('DELETE', `/v1/appScreenshots/${left.shift()}`)
    let id
    try {
      id = await uploadShot(set.id, p)
      await processed(id)
    } catch (err) {
      if (id) await api('DELETE', `/v1/appScreenshots/${id}`).catch(() => {})
      throw new Error(`${err.message}. ${locale} ${type} now has ${added.length} new and ${left.length} old screenshots.`)
    }
    added.push(id)
  }
  for (const id of left) await api('DELETE', `/v1/appScreenshots/${id}`)
  await api('PATCH', `/v1/appScreenshotSets/${set.id}/relationships/appScreenshots`, { data: added.map((id) => ({ type: 'appScreenshots', id })) })
  console.log(`${locale} ${type}: ${added.length} new, ${old.length} old removed`)
}

const command = process.argv[2]
async function iap() {
  const a = await app()
  for (const p of await all(`/v1/apps/${a.id}/inAppPurchasesV2?limit=50`)) {
    console.log(p.attributes)
    for (const rel of ['inAppPurchaseAvailability', 'promotedPurchase', 'inAppPurchaseLocalizations'])
      await api('GET', `/v2/inAppPurchases/${p.id}/${rel}`).then((r) => console.log(rel, JSON.stringify(r.data?.attributes ?? r.data?.map?.((x) => x.attributes) ?? r.data)), (err) => console.log(rel, err.message.slice(0, 200)))
  }
}

const run = { status, apply, diff, iap, shots, 'watch-shots': watchShots, 'replace-shots': replaceShots }[command]
if (!run) { console.log('Usage: node Scripts/asc-listing.mjs status | diff [locale] | apply | watch-shots | shots | replace-shots <locale> <type> <png>...'); process.exit(1) }
run().catch((err) => { console.error(err.message); process.exit(1) })
