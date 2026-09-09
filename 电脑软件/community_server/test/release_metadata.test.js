import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { createCommunityServer, resolveReleaseMetadata } from '../src/server.js';

const desktop = {
  latestVersion: 'v1.2.0+2',
  minSupportedVersion: 'v1.0.0+2',
  forceUpdate: false,
  downloadUrl: 'https://downloads.example.com/sohun.exe',
  releaseNotes: '桌面修复',
};
const android = {
  latestVersion: 'v1.0.0+3',
  minSupportedVersion: 'v1.0.0+2',
  forceUpdate: true,
  downloadUrl: 'https://downloads.example.com/sohun.apk',
  releaseNotes: '手机修复',
};

test('release policies have separate desktop and Android version, notes and URLs', () => {
  const flags = resolveReleaseMetadata({ ...desktop, android });
  assert.equal(flags.desktop_latest_version, desktop.latestVersion);
  assert.equal(flags.desktop_force_update, false);
  assert.equal(flags.desktop_min_supported_version, desktop.minSupportedVersion);
  assert.equal(flags.desktop_download_url, desktop.downloadUrl);
  assert.equal(flags.desktop_release_notes, desktop.releaseNotes);
  assert.equal(flags.android_latest_version, android.latestVersion);
  assert.equal(flags.android_force_update, true);
  assert.equal(flags.android_min_supported_version, android.minSupportedVersion);
  assert.equal(flags.android_download_url, android.downloadUrl);
  assert.equal(flags.android_release_notes, android.releaseNotes);
});

test('force and minimum can be explicitly withdrawn without omitting the keys', () => {
  const flags = resolveReleaseMetadata({
    ...desktop,
    minSupportedVersion: '',
    forceUpdate: 'false',
  });
  assert.equal(flags.desktop_force_update, false);
  assert.equal(flags.desktop_min_supported_version, '');
  assert.equal(resolveReleaseMetadata({ ...desktop, forceUpdate: 'true' }).desktop_force_update, true);
});

test('malformed policy and impossible minimum/build combinations are not published', () => {
  for (const policy of [
    { ...desktop, latestVersion: 'broken' },
    { ...desktop, minSupportedVersion: 'broken' },
    { ...desktop, minSupportedVersion: 'v1.2.0+3' },
    { ...desktop, forceUpdate: 'sometimes' },
    { ...desktop, forceUpdate: 1 },
  ]) {
    assert.deepEqual(resolveReleaseMetadata(policy), {});
  }
});

test('Android does not inherit the desktop installer when its URL is missing', () => {
  const flags = resolveReleaseMetadata({
    ...desktop,
    android: { latestVersion: 'v1.1.0', forceUpdate: true },
  });
  assert.equal(flags.android_latest_version, 'v1.1.0');
  assert.equal(flags.android_force_update, false);
  assert.equal(flags.android_min_supported_version, '');
  assert.equal(flags.android_download_url, undefined);
  assert.equal(flags.desktop_download_url, desktop.downloadUrl);
});

test('unsafe URLs never become download entries and GitHub assets stay platform specific', () => {
  for (const downloadUrl of [
    'http://downloads.example.com/sohun.apk',
    'https://user:password@downloads.example.com/sohun.apk',
    'file:///C:/sohun.apk',
  ]) {
    const flags = resolveReleaseMetadata({ ...desktop, android: { ...android, downloadUrl } });
    assert.equal(flags.android_download_url, undefined);
    assert.equal(flags.android_force_update, false);
    assert.equal(flags.android_min_supported_version, '');
  }
  const flags = resolveReleaseMetadata({
    ...desktop,
    android: {
      latestVersion: 'v1.1.0+2',
      githubRepository: 'example/sohun-client',
      githubReleaseTag: 'v1.1.0',
      installerAsset: 'sohun-android.apk',
    },
  });
  assert.equal(
    flags.android_download_url,
    'https://github.com/example/sohun-client/releases/download/v1.1.0/sohun-android.apk',
  );
});

test('config endpoint returns only the requested platform release and independent ETags', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'sohun-release-policy-'));
  const server = createCommunityServer({
    databasePath: join(directory, 'test.sqlite'),
    passwordPepper: 'test-pepper',
    releaseMetadata: { ...desktop, android },
  });
  t.after(async () => {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    rmSync(directory, { recursive: true, force: true });
  });
  await server.operationalReady;
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const baseUrl = `http://127.0.0.1:${server.address().port}/v1/config?appVersion=v1.0.0%2B1`;
  const desktopResponse = await fetch(`${baseUrl}&platform=windows`);
  const desktopBody = await desktopResponse.json();
  assert.equal(desktopResponse.status, 200);
  assert.equal(desktopBody.flags.desktop_download_url, desktop.downloadUrl);
  assert.equal(desktopBody.flags.android_latest_version, undefined);
  const androidResponse = await fetch(`${baseUrl}&platform=android`, {
    headers: { 'If-None-Match': desktopResponse.headers.get('etag') },
  });
  const androidBody = await androidResponse.json();
  assert.equal(androidResponse.status, 200);
  assert.equal(androidBody.flags.android_download_url, android.downloadUrl);
  assert.equal(androidBody.flags.android_force_update, true);
  assert.equal(androidBody.flags.desktop_latest_version, undefined);
  assert.notEqual(androidResponse.headers.get('etag'), desktopResponse.headers.get('etag'));
  const unchanged = await fetch(`${baseUrl}&platform=android`, {
    headers: { 'If-None-Match': androidResponse.headers.get('etag') },
  });
  assert.equal(unchanged.status, 304);
});
