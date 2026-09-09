import { isAbsolute, resolve } from 'node:path';

import { verifySqliteBackup } from '../src/backup_manager.js';

const input = process.argv[2];
if (!input || !isAbsolute(input)) {
  throw new Error('Pass an absolute SQLite backup path');
}

const result = verifySqliteBackup(resolve(input));
process.stdout.write(`${JSON.stringify(result)}\n`);

