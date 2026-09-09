import { createHash, randomUUID } from 'node:crypto';
import {
  createReadStream,
  existsSync,
  mkdirSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
} from 'node:fs';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { backup as sqliteBackup, DatabaseSync } from 'node:sqlite';

const BACKUP_PREFIX = 'sohun-community-';
const BACKUP_SUFFIX = '.sqlite';

function isoFileStamp(date) {
  return date.toISOString().replaceAll(':', '').replaceAll('-', '');
}

async function sha256File(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

export function validateBackupConfiguration({
  databasePath,
  backupDirectory,
  retentionDays,
  intervalHours,
}) {
  if (typeof backupDirectory !== 'string'
      || backupDirectory !== backupDirectory.trim()
      || !isAbsolute(backupDirectory)) {
    throw new Error('COMMUNITY_BACKUP_DIRECTORY must be an absolute directory');
  }
  if (resolve(backupDirectory) === resolve(dirname(databasePath))) {
    throw new Error(
      'COMMUNITY_BACKUP_DIRECTORY must differ from the live database directory',
    );
  }
  if (!Number.isInteger(retentionDays) || retentionDays < 7 || retentionDays > 3650) {
    throw new Error('COMMUNITY_BACKUP_RETENTION_DAYS must be between 7 and 3650');
  }
  if (!Number.isFinite(intervalHours) || intervalHours < 1 || intervalHours > 168) {
    throw new Error('COMMUNITY_BACKUP_INTERVAL_HOURS must be between 1 and 168');
  }
}

export function verifySqliteBackup(path) {
  if (!existsSync(path) || !statSync(path).isFile()) {
    throw new Error('backup file does not exist');
  }
  const verification = new DatabaseSync(path, { readOnly: true });
  try {
    const result = verification.prepare('PRAGMA integrity_check').all();
    if (result.length !== 1 || result[0].integrity_check !== 'ok') {
      throw new Error('SQLite integrity_check did not return ok');
    }
    const migration = verification.prepare(
      'SELECT MAX(version) AS version FROM community_schema_migrations',
    ).get();
    return { ok: true, schemaVersion: Number(migration?.version ?? 0) };
  } finally {
    verification.close();
  }
}

export function createBackupManager({
  database,
  databasePath,
  backupDirectory,
  retentionDays = 30,
  intervalHours = 24,
  now = () => new Date(),
}) {
  validateBackupConfiguration({
    databasePath,
    backupDirectory,
    retentionDays,
    intervalHours,
  });
  mkdirSync(backupDirectory, { recursive: true });

  let interval = null;
  let operation = null;
  let lastSuccess = null;
  let lastFailure = null;
  let nextRunAt = null;

  function recordRun({
    id,
    fileName,
    status,
    startedAt,
    completedAt,
    bytes = null,
    sha256 = null,
    errorCategory = null,
  }) {
    database.prepare(`
      INSERT INTO backup_runs(
        id, file_name, status, started_at, completed_at,
        bytes, sha256, error_category
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      id,
      fileName,
      status,
      startedAt,
      completedAt,
      bytes,
      sha256,
      errorCategory,
    );
  }

  function prune(referenceTime) {
    const cutoff = referenceTime.getTime() - retentionDays * 24 * 60 * 60 * 1000;
    for (const fileName of readdirSync(backupDirectory)) {
      if (!fileName.startsWith(BACKUP_PREFIX) || !fileName.endsWith(BACKUP_SUFFIX)) {
        continue;
      }
      const fullPath = resolve(backupDirectory, fileName);
      if (dirname(fullPath) !== resolve(backupDirectory)) continue;
      if (statSync(fullPath).mtimeMs < cutoff) {
        rmSync(fullPath, { force: true });
      }
    }
  }

  async function runBackup(trigger = 'manual') {
    if (operation != null) return operation;
    operation = (async () => {
      const started = now();
      const runId = randomUUID();
      const fileName = `${BACKUP_PREFIX}${isoFileStamp(started)}-${runId.slice(0, 8)}${BACKUP_SUFFIX}`;
      const finalPath = resolve(backupDirectory, fileName);
      const temporaryPath = `${finalPath}.partial`;
      if (dirname(finalPath) !== resolve(backupDirectory)
          || basename(fileName) !== fileName) {
        throw new Error('refusing unsafe backup path');
      }
      try {
        await sqliteBackup(database, temporaryPath);
        const verification = verifySqliteBackup(temporaryPath);
        const sha256 = await sha256File(temporaryPath);
        const bytes = statSync(temporaryPath).size;
        renameSync(temporaryPath, finalPath);
        const completedAt = now().toISOString();
        lastSuccess = {
          trigger,
          fileName,
          completedAt,
          bytes,
          sha256,
          schemaVersion: verification.schemaVersion,
        };
        lastFailure = null;
        recordRun({
          id: runId,
          fileName,
          status: 'succeeded',
          startedAt: started.toISOString(),
          completedAt,
          bytes,
          sha256,
        });
        prune(now());
        return { ...lastSuccess, path: finalPath };
      } catch (error) {
        rmSync(temporaryPath, { force: true });
        const completedAt = now().toISOString();
        const category = error?.code ? String(error.code) : 'backup_failed';
        lastFailure = {
          trigger,
          completedAt,
          category,
        };
        recordRun({
          id: runId,
          fileName,
          status: 'failed',
          startedAt: started.toISOString(),
          completedAt,
          errorCategory: category,
        });
        throw error;
      } finally {
        operation = null;
      }
    })();
    return operation;
  }

  function scheduleNext() {
    nextRunAt = new Date(
      now().getTime() + intervalHours * 60 * 60 * 1000,
    ).toISOString();
  }

  function start() {
    if (interval != null) return;
    scheduleNext();
    interval = setInterval(() => {
      runBackup('scheduled').catch((error) => {
        console.error('[backup]', error);
      }).finally(scheduleNext);
    }, intervalHours * 60 * 60 * 1000);
    interval.unref?.();
  }

  function close() {
    if (interval != null) clearInterval(interval);
    interval = null;
  }

  function status() {
    const persisted = database.prepare(`
      SELECT file_name, status, completed_at, bytes, sha256, error_category
      FROM backup_runs
      ORDER BY completed_at DESC
      LIMIT 1
    `).get();
    return {
      configured: true,
      inProgress: operation != null,
      intervalHours,
      retentionDays,
      nextRunAt,
      lastSuccess,
      lastFailure,
      latestPersisted: persisted
        ? {
            fileName: persisted.file_name,
            status: persisted.status,
            completedAt: persisted.completed_at,
            bytes: persisted.bytes,
            sha256: persisted.sha256,
            errorCategory: persisted.error_category,
          }
        : null,
    };
  }

  return { runBackup, start, close, status };
}

