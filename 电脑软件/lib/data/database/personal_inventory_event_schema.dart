import 'package:drift/drift.dart';

/// v51: capture safe events in the same transaction as their source rows.
/// Random event IDs survive retries, source deletion and backup/restore. The
/// source key is local bookkeeping, never a cross-device event identity.
Future<void> preparePersonalInventoryEventOutbox(Migrator m) async {
  final db = m.database;
  final tables =
      (await db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type = 'table'",
              )
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();
  final columns = await db
      .customSelect('PRAGMA table_info(personal_inventory_events)')
      .get();
  final names = columns.map((row) => row.read<String>('name')).toSet();
  for (final entry in {
    'local_source_key': 'TEXT',
    'printer_uid': 'TEXT',
    'printer_name': 'TEXT',
    'channel_index': 'INTEGER',
    'task_uid': 'TEXT',
  }.entries) {
    if (!names.contains(entry.key)) {
      await db.customStatement(
        'ALTER TABLE personal_inventory_events ADD COLUMN ${entry.key} ${entry.value}',
      );
    }
  }
  await db.customStatement('''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_personal_event_source
    ON personal_inventory_events(local_source_key)
    WHERE local_source_key IS NOT NULL
  ''');
  await db.customStatement('''
    CREATE TABLE IF NOT EXISTS personal_inventory_event_receipts(
      owner_account TEXT NOT NULL,
      server_url TEXT NOT NULL,
      event_uid TEXT NOT NULL,
      PRIMARY KEY(owner_account, server_url, event_uid)
    )
  ''');
  await db.customStatement('''
    CREATE TABLE IF NOT EXISTS personal_inventory_event_cursors(
      owner_account TEXT NOT NULL,
      server_url TEXT NOT NULL,
      cursor INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(owner_account, server_url)
    )
  ''');
  for (final table in [
    'personal_inventory_sync_baselines',
    'personal_inventory_balance_conflicts',
  ]) {
    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS $table(
        owner_account TEXT NOT NULL,
        server_url TEXT NOT NULL,
        inventory_uid TEXT NOT NULL,
        record_json TEXT NOT NULL,
        PRIMARY KEY(owner_account, server_url, inventory_uid)
      )
    ''');
  }

  // Do not copy arbitrary log messages, raw reader data, printer serials,
  // access codes or gcode paths into the account ledger.
  const prefix = '''
    INSERT OR IGNORE INTO personal_inventory_events(
      event_uid, owner_account, inventory_uid, rfid_tag_uid, rfid_tag_cycle,
      event_type, before_grams, after_grams, delta_grams, occurred_at,
      source, local_source_key, printer_uid, printer_name, channel_index, task_uid)
  ''';
  const scope = "c.inventory_scope = 'personal' AND trim(c.uid) != ''";
  final taskColumns = tables.contains('print_tasks')
      ? (await db.customSelect('PRAGMA table_info(print_tasks)').get())
            .map((row) => row.read<String>('name'))
            .toSet()
      : <String>{};
  final taskUid = taskColumns.contains('uid') ? "nullif(t.uid, '')" : 'NULL';
  final taskJoin = taskColumns.contains('uid')
      ? 'LEFT JOIN print_tasks t ON t.id = e.task_id'
      : '';
  final projections = <String, ({String table, String key, String sql})>{
    'usage': (
      table: 'usage_logs',
      key: 'u.id',
      sql: '''$prefix
        SELECT 'usage:' || lower(hex(randomblob(16))), lower(trim(c.owner_account)),
          c.uid, nullif(trim(c.rfid_tag_uid), ''),
          CASE WHEN trim(coalesce(c.rfid_tag_uid, '')) != '' THEN c.rfid_tag_cycle END,
          CASE WHEN u.finished = 1 THEN 'usage_finished' ELSE 'usage_partial' END,
          NULL, NULL, -u.consumed_grams, u.logged_at * 1000,
          'usage', 'usage:' || u.id, nullif(p.uid, ''), nullif(substr(trim(p.name), 1, 80), ''), u.channel_index, NULL
        FROM usage_logs u JOIN consumables c ON c.id = u.consumable_id
        LEFT JOIN printers p ON p.id = u.printer_id WHERE $scope''',
    ),
    'nfc': (
      table: 'rfid_tag_records',
      key: 'r.id',
      sql:
          '''$prefix
        SELECT 'nfc:' || lower(hex(randomblob(16))), lower(trim(c.owner_account)),
          c.uid, nullif(trim(c.rfid_tag_uid), ''),
          CASE WHEN trim(coalesce(c.rfid_tag_uid, '')) != '' THEN c.rfid_tag_cycle END,
          'nfc_' || CASE WHEN r.operation IN ('read', 'write', 'bind', 'replace', 'resolve', 'archive')
            THEN r.operation ELSE 'operation' END ||
            CASE WHEN r.status = 'success' THEN '_success' ELSE '_failed' END,
          NULL, NULL, NULL, r.occurred_at, 'nfc', 'nfc:' || r.id,
          NULL, NULL, NULL, NULL
        FROM rfid_tag_records r JOIN consumables c ON lower(c.uid) = lower(r.inventory_uid)
        WHERE $scope AND (coalesce(trim(r.owner_account), '') = '' OR
          lower(trim(r.owner_account)) = lower(trim(c.owner_account)))
          AND (trim(coalesce(c.rfid_tag_uid, '')) = '' OR
            lower(replace(replace(replace(trim(r.tag_uid), ':', ''), '-', ''), ' ', '')) =
            lower(replace(replace(replace(trim(c.rfid_tag_uid), ':', ''), '-', ''), ' ', '')))''',
    ),
    'twin': (
      table: 'consumable_twin_events',
      key: 'e.event_uid',
      sql:
          '''$prefix
        SELECT 'twin:' || lower(hex(randomblob(16))), lower(trim(c.owner_account)),
          c.uid, nullif(trim(c.rfid_tag_uid), ''),
          CASE WHEN trim(coalesce(c.rfid_tag_uid, '')) != '' THEN c.rfid_tag_cycle END,
          'twin_' || substr(e.event_type, 1, 40), e.before_grams, e.after_grams, NULL,
          e.observed_at, 'twin', 'twin:' || e.event_uid,
          nullif(p.uid, ''), nullif(substr(trim(p.name), 1, 80), ''),
          CASE WHEN e.ams_id IS NOT NULL AND e.slot_index IS NOT NULL
            THEN e.ams_id * 4 + e.slot_index ELSE e.slot_index END, $taskUid
        FROM consumable_twin_events e JOIN consumables c ON c.id = e.consumable_id
        LEFT JOIN printers p ON p.id = e.printer_id
        $taskJoin WHERE $scope''',
    ),
  };
  final installed = <String>{};
  for (final entry in projections.entries) {
    final projection = entry.value;
    // Released databases contain these source tables. Minimal old-version
    // recovery databases can omit whole features; migrate only present sources
    // and let genuine SQL/data errors fail the migration instead of swallowing.
    final requiredTables = {
      projection.table,
      'consumables',
      if (entry.key != 'nfc') 'printers',
    };
    if (!tables.containsAll(requiredTables)) continue;
    await db.customStatement(projection.sql);
    final newKey = projection.key.substring(projection.key.indexOf('.') + 1);
    await db.customStatement('''
      CREATE TRIGGER IF NOT EXISTS personal_event_${entry.key}_insert
      AFTER INSERT ON ${projection.table} BEGIN
        ${projection.sql} AND ${projection.key} = NEW.$newKey;
      END
    ''');
    installed.add(entry.key);
  }
  // Some reader operations are linked to their spool after the read succeeds.
  if (installed.contains('nfc'))
    await db.customStatement('''
    CREATE TRIGGER IF NOT EXISTS personal_event_nfc_link
    AFTER UPDATE OF inventory_uid ON rfid_tag_records BEGIN
      ${projections['nfc']!.sql} AND r.id = NEW.id;
    END
  ''');
}
