// Local-only integration fixture. No production accounts or data are used.
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createCommunityServer } from '../../community_server/src/server.js';

const directory = mkdtempSync(join(tmpdir(), 'sohun-inventory-http-'));
const server = createCommunityServer({ databasePath: join(directory, 'test.sqlite'),
  passwordPepper: 'local-integration-fixture', maxPrinterFaultsPerUser: 1 });
await server.operationalReady;
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
process.stdout.write(`http://127.0.0.1:${server.address().port}\n`);
process.stdin.once('data', () => {
  server.close(() => {
    rmSync(directory, { recursive: true, force: true });
    process.exit(0);
  });
});
process.stdin.resume();
