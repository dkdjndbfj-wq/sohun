import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const POLICY_TYPES = new Set(['terms', 'privacy']);

export function createPolicyStore({
  policyRoot,
  termsVersion,
  privacyVersion,
  supportEmail,
}) {
  const root = resolve(policyRoot);
  const versions = {
    terms: termsVersion,
    privacy: privacyVersion,
  };
  const titles = {
    terms: 'sohun 服务条款',
    privacy: 'sohun 隐私政策',
  };

  function read(type, requestedVersion = 'current') {
    if (!POLICY_TYPES.has(type)) return null;
    const currentVersion = versions[type];
    const version = requestedVersion === 'current'
      ? currentVersion
      : requestedVersion;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(version)) return null;
    const path = resolve(root, type, `${version}.md`);
    if (!path.startsWith(`${join(root, type)}\\`)
        && !path.startsWith(`${join(root, type)}/`)) {
      return null;
    }
    let content;
    try {
      content = readFileSync(path, 'utf8');
    } catch {
      return null;
    }
    content = content.replaceAll('{{SUPPORT_EMAIL}}', supportEmail);
    return {
      type,
      version,
      current: version === currentVersion,
      title: titles[type],
      effectiveAt: `${version}T00:00:00.000Z`,
      content,
    };
  }

  for (const type of POLICY_TYPES) {
    if (read(type) == null) {
      throw new Error(`Missing current ${type} policy document`);
    }
  }

  return { read };
}

