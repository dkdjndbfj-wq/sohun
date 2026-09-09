#!/usr/bin/env node

/**
 * Generate and import one-time support codes.
 *
 * The server stores only HMAC digests of codes. This helper deliberately keeps
 * plaintext codes on the operator's machine only long enough to distribute
 * them or send them over the authenticated HTTPS admin endpoint.
 */

import { readFile, writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { parseArgs } from 'node:util';

const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const CODE_LENGTH = 32;
const MAX_GENERATE = 5000;
const MAX_IMPORT_BATCH = 500;

// The four paid products exposed by the third-party support shop.  The
// canonical labels are stored in the support wall; numeric/short aliases are
// accepted on the command line so an operator can type `--tier 10`.
const SUPPORT_TIERS = Object.freeze([
  { amount: 10, label: '10元支持' },
  { amount: 20, label: '20元支持' },
  { amount: 50, label: '50元支持' },
  { amount: 100, label: '100元支持' },
]);

const TIER_ALIASES = new Map(
  SUPPORT_TIERS.flatMap(({ amount, label }) => [
    [String(amount), label],
    [`${amount}元`, label],
    [`${amount} 元`, label],
    [`${amount}元支持`, label],
    [`${amount} 元支持`, label],
    [`¥${amount}`, label],
    [`￥${amount}`, label],
  ]),
);

function usage() {
  return `Usage:
  node scripts/support_codes.mjs generate --count 100 --tier 10 --out support-codes.json
  node scripts/support_codes.mjs import --file support-codes.json --base-url https://api.example.com

Options:
  generate  --count <1-5000> [--tier <10|20|50|100>] [--label <text>] [--out <file>]
  import    --file <json-or-lines> --base-url <https-url> [--tier <10|20|50|100>] [--admin-token <token>]

Supported tiers: ${SUPPORT_TIERS.map(({ label }) => label).join('、')}
Numeric aliases are normalized to the labels above. Custom tier labels are
still accepted when importing legacy or manually issued third-party codes.

COMMUNITY_ADMIN_TOKEN may be used instead of --admin-token. Do not put the
admin token in source files or commit generated code files.
`;
}

function fail(message) {
  throw new Error(message);
}

function stringOption(values, name, fallback = '') {
  const value = values[name];
  if (value == null) return fallback;
  const text = String(value).trim();
  return text;
}

function normalizeTier(raw, fallback = '10元支持') {
  const text = String(raw ?? '').trim();
  if (!text) return fallback;
  return TIER_ALIASES.get(text.toLowerCase()) ?? text;
}

function positiveIntegerOption(values, name, { min, max }) {
  const raw = stringOption(values, name);
  if (!/^\d+$/.test(raw)) {
    fail(`--${name} must be an integer between ${min} and ${max}`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    fail(`--${name} must be an integer between ${min} and ${max}`);
  }
  return value;
}

function secureCode() {
  const chars = [];
  // Rejection sampling avoids modulo bias when mapping random bytes onto the
  // human-friendly alphabet (which has 32 symbols).
  while (chars.length < CODE_LENGTH) {
    for (const byte of randomBytes(64)) {
      const limit = 256 - (256 % ALPHABET.length);
      if (byte >= limit) continue;
      chars.push(ALPHABET[byte % ALPHABET.length]);
      if (chars.length === CODE_LENGTH) break;
    }
  }
  const groups = chars.join('').match(/.{1,4}/g) ?? [];
  return `SOHUN-${groups.join('-')}`;
}

function generateCodes(count, tier, displayLabel) {
  const seen = new Set();
  const codes = [];
  while (codes.length < count) {
    const code = secureCode();
    if (!seen.add(code)) continue;
    codes.push({
      code,
      tier,
      ...(displayLabel ? { displayLabel } : {}),
    });
  }
  return codes;
}

function normalizeBaseUrl(raw) {
  if (!raw) fail('Missing --base-url or COMMUNITY_PUBLIC_BASE_URL');
  let url;
  try {
    url = new URL(raw);
  } catch {
    fail('--base-url must be an absolute HTTP(S) URL');
  }
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname) {
    fail('--base-url must be an absolute HTTP(S) URL');
  }
  if (url.username || url.password || url.search || url.hash) {
    fail('--base-url must not contain credentials, query parameters, or fragments');
  }
  if (url.protocol === 'http:' && !isLoopback(url.hostname)) {
    fail('Non-loopback --base-url values must use HTTPS');
  }
  return url.toString().replace(/\/+$/, '');
}

function isLoopback(hostname) {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, '');
  if (host === 'localhost' || host === '::1') return true;
  const octets = host.split('.');
  return octets.length === 4 && octets[0] === '127' &&
    octets.slice(1).every((part) => /^\d+$/.test(part) && Number(part) <= 255);
}

function normalizeCodeEntry(value, defaultTier) {
  if (typeof value === 'string') {
    const code = value.trim();
    if (!code) return null;
    if (code.length < 8 || code.length > 200) {
      fail('Each support code must be between 8 and 200 characters');
    }
    return { code, tier: defaultTier };
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const code = String(value.code ?? '').trim();
  if (!code) return null;
  if (code.length < 8 || code.length > 200) {
    fail('Each support code must be between 8 and 200 characters');
  }
  const tier = normalizeTier(value.tier ?? defaultTier, defaultTier);
  if (tier.length > 40) fail('Support-code tiers are limited to 40 characters');
  const displayLabel = String(value.displayLabel ?? value.label ?? '').trim();
  if (displayLabel.length > 80) {
    fail('Support-code display labels are limited to 80 characters');
  }
  return {
    code,
    tier,
    ...(displayLabel ? { displayLabel } : {}),
  };
}

async function readCodeFile(file, defaultTier) {
  if (!file) fail('Missing --file');
  const raw = await readFile(file, 'utf8');
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    parsed = raw.split(/\r?\n/)
      .map((line) => line.replace(/\s+#.*$/, '').trim())
      .filter(Boolean);
  }
  const values = Array.isArray(parsed) ? parsed : parsed?.codes;
  if (!Array.isArray(values)) {
    fail('The code file must be a JSON array, {"codes": [...]}, or one code per line');
  }
  const entries = values
    .map((value) => normalizeCodeEntry(value, defaultTier))
    .filter((value) => value != null);
  if (entries.length === 0) fail('The code file contains no usable codes');
  if (entries.length > 5000) fail('A single import is limited to 5000 codes');
  return entries;
}

async function importCodes(entries, baseUrl, adminToken) {
  if (!adminToken) fail('Missing --admin-token or COMMUNITY_ADMIN_TOKEN');
  if (/\r|\n/.test(adminToken)) fail('The admin token contains a newline');
  let inserted = 0;
  let batches = 0;
  for (let offset = 0; offset < entries.length; offset += MAX_IMPORT_BATCH) {
    const batch = entries.slice(offset, offset + MAX_IMPORT_BATCH);
    const response = await fetch(`${baseUrl}/v1/admin/support-codes`, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        Authorization: `Bearer ${adminToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ codes: batch }),
    });
    const text = await response.text();
    let body;
    try {
      body = text ? JSON.parse(text) : null;
    } catch {
      body = null;
    }
    if (!response.ok) {
      const detail = body?.message ?? body?.error ?? `HTTP ${response.status}`;
      fail(`Import failed for batch ${batches + 1}: ${String(detail).slice(0, 240)}`);
    }
    if (!body || typeof body.inserted !== 'number') {
      fail(`Import failed for batch ${batches + 1}: incompatible server response`);
    }
    inserted += body.inserted;
    batches += 1;
  }
  return { requested: entries.length, inserted, batches };
}

async function main() {
  const command = process.argv[2] ?? 'help';
  if (command === 'help' || command === '--help' || command === '-h') {
    process.stdout.write(usage());
    return;
  }
  const parsed = parseArgs({
    args: process.argv.slice(3),
    options: {
      count: { type: 'string', short: 'n' },
      tier: { type: 'string', short: 't' },
      label: { type: 'string', short: 'l' },
      out: { type: 'string', short: 'o' },
      file: { type: 'string', short: 'f' },
      'base-url': { type: 'string', short: 'u' },
      'admin-token': { type: 'string' },
    },
    strict: true,
  });

  if (command === 'generate') {
    const count = positiveIntegerOption(parsed.values, 'count', {
      min: 1,
      max: MAX_GENERATE,
    });
    const tier = normalizeTier(stringOption(parsed.values, 'tier'), '10元支持');
    const displayLabel = stringOption(parsed.values, 'label');
    if (tier.length > 40 || displayLabel.length > 80) {
      fail('--tier is limited to 40 characters and --label to 80 characters');
    }
    const entries = generateCodes(count, tier, displayLabel);
    const payload = {
      generatedAt: new Date().toISOString(),
      codes: entries,
    };
    const out = stringOption(parsed.values, 'out');
    if (out) {
      await writeFile(out, `${JSON.stringify(payload, null, 2)}\n`, {
        encoding: 'utf8',
        mode: 0o600,
      });
      process.stdout.write(`Generated ${entries.length} codes in ${out}. Keep this file private.\n`);
      return;
    }
    process.stdout.write(`${entries.map((entry) => entry.code).join('\n')}\n`);
    return;
  }

  if (command === 'import') {
    const defaultTier = normalizeTier(stringOption(parsed.values, 'tier'), '10元支持');
    if (!defaultTier || defaultTier.length > 40) {
      fail('--tier is required and limited to 40 characters');
    }
    const entries = await readCodeFile(stringOption(parsed.values, 'file'), defaultTier);
    const baseUrl = normalizeBaseUrl(
      stringOption(parsed.values, 'base-url') || process.env.COMMUNITY_PUBLIC_BASE_URL,
    );
    const adminToken = stringOption(parsed.values, 'admin-token') ||
      String(process.env.COMMUNITY_ADMIN_TOKEN ?? '').trim();
    const result = await importCodes(entries, baseUrl, adminToken);
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return;
  }

  process.stderr.write(usage());
  process.exitCode = 2;
}

main().catch((error) => {
  process.stderr.write(`Error: ${error.message}\n`);
  process.exitCode = 1;
});
