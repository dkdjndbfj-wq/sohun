// 社区服务端数据库结构迁移执行器。
//
// 任务书 Phase E 要求：
// - 当前服务端只有 `CREATE TABLE IF NOT EXISTS`，已有表新增字段不会自动升级。
// - 先建立 `community_schema_migrations(version, applied_at)` 和事务化迁移执行器。
// - 用现有 SQLite fixture 验证账号、参数和点赞不丢失，禁止靠删库升级。
//
// 任务书 Phase F 要求：
// - telemetry_events 和 feature_flags 表纳入 community_schema_migrations。
// - 服务端不得保存客户端未允许的属性；本轮只运行临时本地实例，不部署。
//
// 所有迁移必须是幂等的：重复执行不应抛错，已应用的迁移应跳过。
// 迁移在事务中执行，任一步失败则回滚并抛出，避免半成品结构。

import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';

/**
 * 已知迁移列表，按 version 升序。
 * 每个迁移是 { version, description, up(database) }。
 *
 * 新增迁移必须追加到末尾，禁止插入或重排，避免已应用迁移的 version 漂移。
 */
export const MIGRATIONS = [
  {
    version: 1,
    description: 'initial schema (users, sessions, presets, preset_likes)',
    up(_db) {
      // 初始 schema 由 initializeDatabase 中的 CREATE TABLE IF NOT EXISTS 完成。
      // 此迁移仅作为占位，记录初始版本。新建库会跳过此迁移（已存在表），
      // 升级库会应用此迁移并写入 community_schema_migrations，标记初始版本已就绪。
    },
  },
  {
    version: 2,
    description: 'preset_versions: immutable versioned preset snapshots',
    up(db) {
      db.exec(`
        CREATE TABLE IF NOT EXISTS preset_versions (
          preset_id TEXT NOT NULL REFERENCES presets(id) ON DELETE CASCADE,
          revision INTEGER NOT NULL,
          content_hash TEXT NOT NULL,
          preset_json TEXT NOT NULL,
          created_at TEXT NOT NULL,
          PRIMARY KEY (preset_id, revision)
        );
        CREATE INDEX IF NOT EXISTS preset_versions_hash_idx
          ON preset_versions(content_hash);
      `);
      // 启动迁移对现有参数当前 revision 做幂等回填。
      // 旧 revision 的结果必须永久留在旧版本统计中。
      const presets = db.prepare('SELECT id, preset_json, revision, updated_at FROM presets').all();
      const insertVersion = db.prepare(`
        INSERT OR IGNORE INTO preset_versions(preset_id, revision, content_hash, preset_json, created_at)
        VALUES (?, ?, ?, ?, ?)
      `);
      for (const p of presets) {
        const hash = contentHashOf(p.preset_json);
        insertVersion.run(p.id, p.revision, hash, p.preset_json, p.updated_at);
      }
    },
  },
  {
    version: 3,
    description: 'preset_print_results: anonymized community print records',
    up(db) {
      db.exec(`
        CREATE TABLE IF NOT EXISTS preset_print_results (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          preset_id TEXT NOT NULL REFERENCES presets(id) ON DELETE CASCADE,
          publication_revision INTEGER NOT NULL,
          preset_fingerprint TEXT NOT NULL,
          client_result_id TEXT NOT NULL,
          technical_status TEXT NOT NULL CHECK(technical_status IN ('finished', 'failed', 'cancelled')),
          user_outcome TEXT CHECK(user_outcome IS NULL OR user_outcome IN ('success', 'usable', 'quality_failed')),
          printer_model TEXT,
          nozzle_diameter REAL,
          material_profile TEXT,
          plate_type TEXT,
          humidity_bucket TEXT CHECK(humidity_bucket IS NULL OR humidity_bucket IN ('low', 'medium', 'high')),
          estimated_seconds INTEGER,
          actual_seconds INTEGER,
          estimated_grams REAL,
          actual_grams REAL,
          rating INTEGER CHECK(rating IS NULL OR (rating >= 1 AND rating <= 5)),
          recorded_at TEXT NOT NULL,
          received_at TEXT NOT NULL,
          revision INTEGER NOT NULL DEFAULT 1,
          audit_status TEXT NOT NULL DEFAULT 'active' CHECK(audit_status IN ('active', 'hidden', 'removed')),
          UNIQUE(user_id, client_result_id)
        );
        CREATE INDEX IF NOT EXISTS preset_print_results_preset_idx
          ON preset_print_results(preset_id, audit_status, received_at DESC);
        CREATE INDEX IF NOT EXISTS preset_print_results_user_idx
          ON preset_print_results(user_id, received_at DESC);
      `);
    },
  },
  {
    version: 4,
    description: 'preset_applications: idempotent application ledger for logged-in users',
    up(db) {
      db.exec(`
        CREATE TABLE IF NOT EXISTS preset_applications (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          preset_id TEXT NOT NULL REFERENCES presets(id) ON DELETE CASCADE,
          publication_revision INTEGER NOT NULL,
          client_application_id TEXT NOT NULL,
          applied_at TEXT NOT NULL,
          UNIQUE(user_id, client_application_id)
        );
        CREATE INDEX IF NOT EXISTS preset_applications_preset_idx
          ON preset_applications(preset_id, applied_at DESC);
      `);
    },
  },
  {
    version: 5,
    description: 'preset_reports: community moderation reports',
    up(db) {
      // 任务书 10.5：同一用户对同一参数同一活动举报只能有一条。
      // SQLite 不允许在 UNIQUE 约束中使用表达式（"expressions prohibited in
      // PRIMARY KEY and UNIQUE constraints"），因此使用 partial unique index
      // 实现"同一 (preset_id, reporter_id) 在 status IN ('open','reviewing')
      // 时唯一"的语义。已 resolved/rejected 的举报不阻止用户再次举报新问题。
      db.exec(`
        CREATE TABLE IF NOT EXISTS preset_reports (
          id TEXT PRIMARY KEY,
          preset_id TEXT NOT NULL REFERENCES presets(id) ON DELETE CASCADE,
          reporter_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          reason TEXT NOT NULL CHECK(reason IN (
            'dangerous_params', 'misleading_description',
            'infringement_or_impersonation', 'spam', 'other'
          )),
          note TEXT,
          status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open', 'reviewing', 'resolved', 'rejected')),
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          resolved_at TEXT,
          resolution_note TEXT
        );
        CREATE UNIQUE INDEX IF NOT EXISTS preset_reports_active_unique_idx
          ON preset_reports(preset_id, reporter_id)
          WHERE status IN ('open', 'reviewing');
        CREATE INDEX IF NOT EXISTS preset_reports_preset_idx
          ON preset_reports(preset_id, status, created_at DESC);
      `);
    },
  },
  {
    version: 6,
    description: 'moderation_actions: audit log for moderation decisions',
    up(db) {
      db.exec(`
        CREATE TABLE IF NOT EXISTS moderation_actions (
          id TEXT PRIMARY KEY,
          moderator_id TEXT REFERENCES users(id) ON DELETE SET NULL,
          target_preset_id TEXT REFERENCES presets(id) ON DELETE CASCADE,
          target_report_id TEXT REFERENCES preset_reports(id) ON DELETE SET NULL,
          action TEXT NOT NULL,
          reason TEXT,
          created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS moderation_actions_target_idx
          ON moderation_actions(target_preset_id, created_at DESC);
      `);
    },
  },
  {
    version: 7,
    description: 'telemetry_events: idempotent anonymized diagnostic events',
    up(db) {
      db.exec(`
        CREATE TABLE IF NOT EXISTS telemetry_events (
          id TEXT PRIMARY KEY,
          install_id_hash TEXT NOT NULL,
          event_name TEXT NOT NULL,
          result_category TEXT,
          duration_ms INTEGER,
          attributes_json TEXT NOT NULL DEFAULT '{}',
          received_at TEXT NOT NULL,
          UNIQUE(install_id_hash, id)
        );
        CREATE INDEX IF NOT EXISTS telemetry_events_name_idx
          ON telemetry_events(event_name, received_at DESC);
        CREATE INDEX IF NOT EXISTS telemetry_events_install_idx
          ON telemetry_events(install_id_hash, received_at DESC);
      `);
    },
  },
  {
    version: 8,
    description: 'feature_flags: versioned remote configuration flags',
    up(db) {
      db.exec(`
        CREATE TABLE IF NOT EXISTS feature_flags (
          key TEXT PRIMARY KEY,
          value_json TEXT NOT NULL,
          schema_version INTEGER NOT NULL DEFAULT 1,
          updated_at TEXT NOT NULL,
          min_app_version TEXT,
          max_app_version TEXT
        );
      `);
    },
  },
  {
    version: 9,
    description: 'account consent versions and last login timestamp',
    up(db) {
      const columns = new Set(
        db.prepare('PRAGMA table_info(users)').all().map((row) => row.name),
      );
      for (const [name, type] of [
        ['terms_version', 'TEXT'],
        ['privacy_version', 'TEXT'],
        ['terms_accepted_at', 'TEXT'],
        ['last_login_at', 'TEXT'],
      ]) {
        if (!columns.has(name)) {
          db.exec(`ALTER TABLE users ADD COLUMN ${name} ${type};`);
        }
      }
    },
  },
  {
    version: 10,
    description: 'account lifecycle tokens, policy history, deletion audit and backup runs',
    up(db) {
      db.exec(`
        CREATE TABLE IF NOT EXISTS account_action_tokens (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          purpose TEXT NOT NULL CHECK(purpose IN ('verify_email', 'reset_password')),
          token_hash TEXT NOT NULL UNIQUE,
          expires_at TEXT NOT NULL,
          attempt_count INTEGER NOT NULL DEFAULT 0,
          max_attempts INTEGER NOT NULL DEFAULT 5,
          consumed_at TEXT,
          created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS account_action_tokens_active_idx
          ON account_action_tokens(user_id, purpose, expires_at DESC);

        CREATE TABLE IF NOT EXISTS account_policy_acceptances (
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          terms_version TEXT NOT NULL,
          privacy_version TEXT NOT NULL,
          accepted_at TEXT NOT NULL,
          PRIMARY KEY(user_id, terms_version, privacy_version)
        );

        CREATE TABLE IF NOT EXISTS deleted_account_tombstones (
          id_hash TEXT PRIMARY KEY,
          email_hash TEXT NOT NULL,
          deleted_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS email_delivery_events (
          id TEXT PRIMARY KEY,
          user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
          purpose TEXT NOT NULL CHECK(purpose IN ('verify_email', 'reset_password')),
          status TEXT NOT NULL CHECK(status IN ('sent', 'failed')),
          provider_message_id TEXT,
          error_category TEXT,
          created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS email_delivery_events_created_idx
          ON email_delivery_events(created_at DESC);

        CREATE TABLE IF NOT EXISTS backup_runs (
          id TEXT PRIMARY KEY,
          file_name TEXT NOT NULL,
          status TEXT NOT NULL CHECK(status IN ('succeeded', 'failed')),
          started_at TEXT NOT NULL,
          completed_at TEXT NOT NULL,
          bytes INTEGER,
          sha256 TEXT,
          error_category TEXT
        );
        CREATE INDEX IF NOT EXISTS backup_runs_completed_idx
          ON backup_runs(completed_at DESC);
      `);

      db.prepare(`
        INSERT OR IGNORE INTO account_policy_acceptances(
          user_id, terms_version, privacy_version, accepted_at
        )
        SELECT id, terms_version, privacy_version, terms_accepted_at
        FROM users
        WHERE terms_version IS NOT NULL
          AND privacy_version IS NOT NULL
          AND terms_accepted_at IS NOT NULL
      `).run();
    },
  },
  {
    version: 11,
    description: 'deduplicate preset applications by account, preset and revision',
    up(db) {
      db.exec(`
        DELETE FROM preset_applications
        WHERE rowid NOT IN (
          SELECT MIN(rowid)
          FROM preset_applications
          GROUP BY user_id, preset_id, publication_revision
        );

        CREATE UNIQUE INDEX IF NOT EXISTS preset_applications_user_preset_revision_idx
          ON preset_applications(user_id, preset_id, publication_revision);

        UPDATE presets
        SET downloads = (
          SELECT COUNT(DISTINCT applications.user_id)
          FROM preset_applications applications
          WHERE applications.preset_id = presets.id
        );
      `);
    },
  },
  {
    version: 12,
    description: 'studio workspaces, role membership, revisioned snapshots and customer share links',
    up(db) {
      db.exec(`
        CREATE TABLE IF NOT EXISTS studio_workspaces (
          id TEXT PRIMARY KEY,
          owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS studio_members (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
          user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
          email TEXT NOT NULL COLLATE NOCASE,
          display_name TEXT NOT NULL,
          role TEXT NOT NULL CHECK(role IN ('owner', 'admin', 'operator')),
          active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          UNIQUE(workspace_id, email)
        );
        CREATE INDEX IF NOT EXISTS studio_members_user_idx
          ON studio_members(user_id, active, workspace_id);
        CREATE TABLE IF NOT EXISTS studio_snapshots (
          workspace_id TEXT PRIMARY KEY REFERENCES studio_workspaces(id) ON DELETE CASCADE,
          revision INTEGER NOT NULL DEFAULT 0,
          payload_json TEXT NOT NULL DEFAULT '{}',
          updated_by TEXT REFERENCES users(id) ON DELETE SET NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS studio_share_links (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
          order_id TEXT NOT NULL,
          token_hash TEXT NOT NULL UNIQUE,
          token_preview TEXT NOT NULL,
          active INTEGER NOT NULL DEFAULT 1,
          expires_at TEXT,
          created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
          created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS studio_share_links_workspace_idx
          ON studio_share_links(workspace_id, active, created_at DESC);
        CREATE TABLE IF NOT EXISTS studio_audit_events (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
          actor_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
          action TEXT NOT NULL,
          subject_id TEXT,
          created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS studio_audit_events_workspace_idx
          ON studio_audit_events(workspace_id, created_at DESC);
      `);
    },
  },
  {
    version: 13,
    description: 'password protected studio portals and order-scoped ephemeral video relay',
    up(db) {
      const shareColumns = new Set(
        db.prepare('PRAGMA table_info(studio_share_links)').all().map((row) => row.name),
      );
      for (const [name, type] of [
        ['password_hash', 'TEXT'],
        ['failed_attempts', 'INTEGER NOT NULL DEFAULT 0'],
        ['locked_until', 'TEXT'],
      ]) {
        if (!shareColumns.has(name)) {
          db.exec(`ALTER TABLE studio_share_links ADD COLUMN ${name} ${type};`);
        }
      }
      db.exec(`
        CREATE TABLE IF NOT EXISTS studio_portal_sessions (
          id TEXT PRIMARY KEY,
          share_id TEXT NOT NULL REFERENCES studio_share_links(id) ON DELETE CASCADE,
          token_hash TEXT NOT NULL UNIQUE,
          expires_at TEXT NOT NULL,
          created_at TEXT NOT NULL,
          last_seen_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS studio_portal_sessions_share_idx
          ON studio_portal_sessions(share_id, expires_at);

        CREATE TABLE IF NOT EXISTS studio_video_sessions (
          id TEXT PRIMARY KEY,
          workspace_id TEXT NOT NULL REFERENCES studio_workspaces(id) ON DELETE CASCADE,
          order_id TEXT NOT NULL,
          work_order_id TEXT NOT NULL,
          upload_token_hash TEXT NOT NULL UNIQUE,
          public_printer_name TEXT NOT NULL,
          active INTEGER NOT NULL DEFAULT 1,
          expires_at TEXT NOT NULL,
          last_frame_at TEXT,
          created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
          created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS studio_video_sessions_order_idx
          ON studio_video_sessions(workspace_id, order_id, active, created_at DESC);
      `);
    },
  },
  {
    version: 14,
    description: 'farm organizations, staged verification, staff identities, scoped RBAC and security audit',
    up(db) {
      const memberColumns = new Set(
        db.prepare('PRAGMA table_info(studio_members)').all().map((row) => row.name),
      );
      for (const [name, type] of [
        ['login_name', 'TEXT'],
        ['employee_no', 'TEXT'],
        ['phone', 'TEXT'],
        ['recovery_email', 'TEXT'],
        ['account_status', "TEXT NOT NULL DEFAULT 'active'"],
        ['primary_role_code', "TEXT NOT NULL DEFAULT 'print_operator'"],
        ['must_change_password', 'INTEGER NOT NULL DEFAULT 0'],
        ['last_login_at', 'TEXT'],
        ['deactivated_at', 'TEXT'],
      ]) {
        if (!memberColumns.has(name)) {
          db.exec(`ALTER TABLE studio_members ADD COLUMN ${name} ${type};`);
        }
      }

      db.exec(`
        CREATE TABLE IF NOT EXISTS farm_organizations (
          id TEXT PRIMARY KEY REFERENCES studio_workspaces(id) ON DELETE CASCADE,
          organization_code TEXT NOT NULL UNIQUE COLLATE NOCASE,
          owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
          display_name TEXT NOT NULL,
          legal_name TEXT,
          subject_type TEXT NOT NULL DEFAULT 'unregistered_studio'
            CHECK(subject_type IN ('company', 'sole_proprietor', 'studio', 'individual_operator', 'unregistered_studio')),
          registration_number TEXT,
          contact_name TEXT,
          contact_phone TEXT,
          contact_email TEXT,
          region TEXT,
          business_address TEXT,
          service_area TEXT,
          printer_count INTEGER NOT NULL DEFAULT 0 CHECK(printer_count >= 0),
          staff_count INTEGER NOT NULL DEFAULT 0 CHECK(staff_count >= 0),
          location_count INTEGER NOT NULL DEFAULT 1 CHECK(location_count >= 1),
          printer_models_json TEXT NOT NULL DEFAULT '[]',
          materials_json TEXT NOT NULL DEFAULT '[]',
          order_types_json TEXT NOT NULL DEFAULT '[]',
          invoice_capability INTEGER NOT NULL DEFAULT 0,
          verification_status TEXT NOT NULL DEFAULT 'draft'
            CHECK(verification_status IN ('draft', 'pending_submission', 'under_review', 'needs_information', 'verified', 'rejected', 'suspended')),
          verification_level INTEGER NOT NULL DEFAULT 0 CHECK(verification_level BETWEEN 0 AND 3),
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS farm_organizations_owner_idx
          ON farm_organizations(owner_user_id, verification_status);

        CREATE TABLE IF NOT EXISTS auth_identity_realms (
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          realm TEXT NOT NULL CHECK(realm IN ('personal', 'farm_owner', 'farm_staff')),
          organization_id TEXT REFERENCES farm_organizations(id) ON DELETE CASCADE,
          created_at TEXT NOT NULL,
          PRIMARY KEY(user_id, realm, organization_id)
        );
        CREATE INDEX IF NOT EXISTS auth_identity_realms_org_idx
          ON auth_identity_realms(organization_id, realm, user_id);

        CREATE TABLE IF NOT EXISTS farm_verification_submissions (
          id TEXT PRIMARY KEY,
          organization_id TEXT NOT NULL REFERENCES farm_organizations(id) ON DELETE CASCADE,
          submission_number INTEGER NOT NULL,
          status TEXT NOT NULL
            CHECK(status IN ('submitted', 'under_review', 'needs_information', 'approved', 'rejected', 'withdrawn')),
          profile_json TEXT NOT NULL,
          document_manifest_json TEXT NOT NULL DEFAULT '[]',
          submitted_by TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
          reviewed_by TEXT REFERENCES users(id) ON DELETE SET NULL,
          review_note TEXT,
          submitted_at TEXT NOT NULL,
          reviewed_at TEXT,
          UNIQUE(organization_id, submission_number)
        );
        CREATE INDEX IF NOT EXISTS farm_verification_submissions_org_idx
          ON farm_verification_submissions(organization_id, submitted_at DESC);

        CREATE TABLE IF NOT EXISTS farm_locations (
          id TEXT PRIMARY KEY,
          organization_id TEXT NOT NULL REFERENCES farm_organizations(id) ON DELETE CASCADE,
          code TEXT NOT NULL COLLATE NOCASE,
          name TEXT NOT NULL,
          address TEXT,
          timezone TEXT NOT NULL DEFAULT 'Asia/Shanghai',
          active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(organization_id, code)
        );

        CREATE TABLE IF NOT EXISTS farm_permissions (
          code TEXT PRIMARY KEY,
          group_code TEXT NOT NULL,
          display_name TEXT NOT NULL,
          sensitive INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS farm_roles (
          id TEXT PRIMARY KEY,
          organization_id TEXT NOT NULL REFERENCES farm_organizations(id) ON DELETE CASCADE,
          code TEXT NOT NULL COLLATE NOCASE,
          display_name TEXT NOT NULL,
          description TEXT,
          system_role INTEGER NOT NULL DEFAULT 0,
          active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(organization_id, code)
        );
        CREATE TABLE IF NOT EXISTS farm_role_permissions (
          role_id TEXT NOT NULL REFERENCES farm_roles(id) ON DELETE CASCADE,
          permission_code TEXT NOT NULL REFERENCES farm_permissions(code) ON DELETE CASCADE,
          PRIMARY KEY(role_id, permission_code)
        );
        CREATE TABLE IF NOT EXISTS farm_member_role_assignments (
          member_id TEXT NOT NULL REFERENCES studio_members(id) ON DELETE CASCADE,
          role_id TEXT NOT NULL REFERENCES farm_roles(id) ON DELETE CASCADE,
          assigned_by TEXT REFERENCES users(id) ON DELETE SET NULL,
          assigned_at TEXT NOT NULL,
          PRIMARY KEY(member_id, role_id)
        );
        CREATE TABLE IF NOT EXISTS farm_member_scopes (
          id TEXT PRIMARY KEY,
          member_id TEXT NOT NULL REFERENCES studio_members(id) ON DELETE CASCADE,
          scope_type TEXT NOT NULL
            CHECK(scope_type IN ('organization', 'location', 'printer_group', 'warehouse', 'order')),
          scope_id TEXT,
          created_at TEXT NOT NULL,
          UNIQUE(member_id, scope_type, scope_id)
        );

        CREATE TABLE IF NOT EXISTS farm_staff_credentials (
          member_id TEXT PRIMARY KEY REFERENCES studio_members(id) ON DELETE CASCADE,
          organization_id TEXT NOT NULL REFERENCES farm_organizations(id) ON DELETE CASCADE,
          user_id TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE RESTRICT,
          login_name TEXT NOT NULL COLLATE NOCASE,
          password_hash TEXT NOT NULL,
          must_change_password INTEGER NOT NULL DEFAULT 1,
          failed_attempts INTEGER NOT NULL DEFAULT 0,
          locked_until TEXT,
          password_changed_at TEXT,
          last_login_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(organization_id, login_name)
        );
        CREATE INDEX IF NOT EXISTS farm_staff_credentials_login_idx
          ON farm_staff_credentials(organization_id, login_name);
        CREATE TABLE IF NOT EXISTS farm_staff_activation_tokens (
          id TEXT PRIMARY KEY,
          member_id TEXT NOT NULL REFERENCES studio_members(id) ON DELETE CASCADE,
          token_hash TEXT NOT NULL UNIQUE,
          expires_at TEXT NOT NULL,
          consumed_at TEXT,
          created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS farm_security_policies (
          organization_id TEXT PRIMARY KEY REFERENCES farm_organizations(id) ON DELETE CASCADE,
          require_mfa_for_privileged INTEGER NOT NULL DEFAULT 1,
          require_mfa_for_all INTEGER NOT NULL DEFAULT 0,
          session_timeout_minutes INTEGER NOT NULL DEFAULT 480,
          idle_timeout_minutes INTEGER NOT NULL DEFAULT 60,
          password_min_length INTEGER NOT NULL DEFAULT 12,
          updated_by TEXT REFERENCES users(id) ON DELETE SET NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS farm_audit_logs (
          id TEXT PRIMARY KEY,
          organization_id TEXT NOT NULL REFERENCES farm_organizations(id) ON DELETE CASCADE,
          actor_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
          actor_member_id TEXT REFERENCES studio_members(id) ON DELETE SET NULL,
          action TEXT NOT NULL,
          resource_type TEXT,
          resource_id TEXT,
          result TEXT NOT NULL DEFAULT 'success' CHECK(result IN ('success', 'denied', 'failed')),
          before_json TEXT,
          after_json TEXT,
          ip_address TEXT,
          user_agent TEXT,
          request_id TEXT,
          created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS farm_audit_logs_org_idx
          ON farm_audit_logs(organization_id, created_at DESC);
        CREATE TABLE IF NOT EXISTS farm_ownership_transfers (
          id TEXT PRIMARY KEY,
          organization_id TEXT NOT NULL REFERENCES farm_organizations(id) ON DELETE CASCADE,
          from_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
          to_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
          status TEXT NOT NULL CHECK(status IN ('pending', 'accepted', 'cancelled', 'expired')),
          expires_at TEXT NOT NULL,
          accepted_at TEXT,
          created_at TEXT NOT NULL
        );
      `);

      const timestamp = new Date().toISOString();
      const permissionRows = [
        ['organization.view', 'organization', '查看农场资料', 0],
        ['organization.update', 'organization', '修改农场资料', 1],
        ['organization.submit_verification', 'organization', '提交主体认证', 1],
        ['organization.transfer_ownership', 'organization', '转移农场所有权', 1],
        ['member.view', 'member', '查看员工', 0],
        ['member.create', 'member', '创建员工账号', 1],
        ['member.update', 'member', '修改员工角色与范围', 1],
        ['member.disable', 'member', '停用员工账号', 1],
        ['member.reset_credential', 'member', '重置员工登录凭据', 1],
        ['order.read', 'order', '查看订单', 0],
        ['order.manage', 'order', '管理订单', 0],
        ['plate.read', 'plate', '查看项目与盘', 0],
        ['plate.slice', 'plate', '执行切片', 0],
        ['job.assign', 'production', '分配生产任务', 0],
        ['job.execute', 'production', '执行生产任务', 0],
        ['printer.read', 'printer', '查看打印机', 0],
        ['printer.control', 'printer', '控制打印机', 1],
        ['printer.maintain', 'printer', '维护打印机', 0],
        ['inventory.read', 'inventory', '查看库存', 0],
        ['inventory.consume', 'inventory', '领用与归还耗材', 0],
        ['inventory.adjust', 'inventory', '调整与盘点库存', 1],
        ['customer.manage', 'customer', '管理客户', 0],
        ['customer.share', 'customer', '管理客户进度链接', 1],
        ['finance.view', 'finance', '查看成本与利润', 1],
        ['finance.manage', 'finance', '管理报价与结算', 1],
        ['audit.view', 'security', '查看审计记录', 1],
        ['workspace.snapshot.write', 'legacy', '写入旧版工作室快照', 1],
      ];
      const insertPermission = db.prepare(`
        INSERT OR IGNORE INTO farm_permissions(code, group_code, display_name, sensitive)
        VALUES (?, ?, ?, ?)
      `);
      for (const row of permissionRows) insertPermission.run(...row);

      const rolePermissions = {
        farm_admin: permissionRows.map((row) => row[0]).filter((code) =>
          !['organization.transfer_ownership'].includes(code)),
        production_manager: ['organization.view', 'member.view', 'order.read', 'order.manage', 'plate.read', 'job.assign', 'job.execute', 'printer.read', 'inventory.read'],
        slicer: ['organization.view', 'order.read', 'plate.read', 'plate.slice'],
        print_operator: ['organization.view', 'order.read', 'plate.read', 'job.execute', 'printer.read', 'printer.control', 'inventory.read', 'inventory.consume'],
        maintenance: ['organization.view', 'printer.read', 'printer.control', 'printer.maintain', 'inventory.read'],
        inventory_manager: ['organization.view', 'inventory.read', 'inventory.consume', 'inventory.adjust'],
        finance_customer: ['organization.view', 'order.read', 'order.manage', 'customer.manage', 'customer.share', 'finance.view', 'finance.manage'],
        auditor: ['organization.view', 'member.view', 'order.read', 'plate.read', 'printer.read', 'inventory.read', 'finance.view', 'audit.view'],
      };
      const roleNames = {
        owner: ['农场所有者', '主体、账单、安全策略及所有权限'],
        farm_admin: ['农场管理员', '员工、设备、订单和日常配置'],
        production_manager: ['生产主管', '排产、工单分配和生产异常'],
        slicer: ['切片员', '按项目和盘执行切片'],
        print_operator: ['打印操作员', '领取并执行打印任务'],
        maintenance: ['设备维护员', '设备接入、维护和故障处理'],
        inventory_manager: ['库存管理员', '入库、领用、盘点和调整'],
        finance_customer: ['客服与财务', '客户、报价、结算和利润'],
        auditor: ['只读审计员', '只读报表和审计记录'],
      };

      const workspaces = db.prepare('SELECT * FROM studio_workspaces').all();
      for (const workspace of workspaces) {
        const codeSeed = createHash('sha256').update(workspace.id).digest('hex').slice(0, 8).toUpperCase();
        const organizationCode = `F${codeSeed}`;
        db.prepare(`
          INSERT OR IGNORE INTO farm_organizations(
            id, organization_code, owner_user_id, display_name, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?)
        `).run(
          workspace.id,
          organizationCode,
          workspace.owner_user_id,
          workspace.name,
          workspace.created_at,
          workspace.updated_at,
        );
        db.prepare(`
          INSERT OR IGNORE INTO auth_identity_realms(user_id, realm, organization_id, created_at)
          VALUES (?, 'farm_owner', ?, ?)
        `).run(workspace.owner_user_id, workspace.id, timestamp);
        db.prepare(`
          INSERT OR IGNORE INTO farm_security_policies(organization_id, updated_by, updated_at)
          VALUES (?, ?, ?)
        `).run(workspace.id, workspace.owner_user_id, timestamp);

        const roleIdByCode = new Map();
        for (const [code, [displayName, description]] of Object.entries(roleNames)) {
          const roleId = `system:${workspace.id}:${code}`;
          roleIdByCode.set(code, roleId);
          db.prepare(`
            INSERT OR IGNORE INTO farm_roles(
              id, organization_id, code, display_name, description, system_role, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, 1, ?, ?)
          `).run(roleId, workspace.id, code, displayName, description, timestamp, timestamp);
          if (code !== 'owner') {
            const insertRolePermission = db.prepare(`
              INSERT OR IGNORE INTO farm_role_permissions(role_id, permission_code)
              VALUES (?, ?)
            `);
            for (const permission of rolePermissions[code] ?? []) {
              insertRolePermission.run(roleId, permission);
            }
          }
        }

        const members = db.prepare('SELECT * FROM studio_members WHERE workspace_id = ?').all(workspace.id);
        for (const member of members) {
          const roleCode = member.role === 'owner'
            ? 'owner'
            : member.role === 'admin' ? 'farm_admin' : 'print_operator';
          db.prepare(`
            UPDATE studio_members
            SET account_status = CASE WHEN active = 1 THEN 'active' ELSE 'deactivated' END,
                primary_role_code = ?
            WHERE id = ?
          `).run(roleCode, member.id);
          db.prepare(`
            INSERT OR IGNORE INTO farm_member_role_assignments(member_id, role_id, assigned_by, assigned_at)
            VALUES (?, ?, ?, ?)
          `).run(member.id, roleIdByCode.get(roleCode), workspace.owner_user_id, timestamp);
          db.prepare(`
            INSERT OR IGNORE INTO farm_member_scopes(id, member_id, scope_type, scope_id, created_at)
            VALUES (?, ?, 'organization', NULL, ?)
          `).run(`scope:${member.id}:organization`, member.id, timestamp);
        }
      }

      const users = db.prepare('SELECT id, created_at FROM users').all();
      for (const user of users) {
        db.prepare(`
          INSERT OR IGNORE INTO auth_identity_realms(user_id, realm, organization_id, created_at)
          VALUES (?, 'personal', NULL, ?)
        `).run(user.id, user.created_at ?? timestamp);
      }
    },
  },
  {
    version: 15,
    description: 'collapse farm positions into administrator and member identities',
    up(db) {
      const timestamp = new Date().toISOString();
      const permissions = db.prepare(
        "SELECT code FROM farm_permissions WHERE code != 'organization.transfer_ownership'",
      ).all();
      const organizations = db.prepare(
        'SELECT id, owner_user_id FROM farm_organizations',
      ).all();
      for (const organization of organizations) {
        const memberRoleId = `system:${organization.id}:member`;
        db.prepare(`
          INSERT INTO farm_roles(
            id, organization_id, code, display_name, description,
            system_role, active, created_at, updated_at
          ) VALUES (?, ?, 'member', '成员', '共享农场数据并使用全部农场功能', 1, 1, ?, ?)
          ON CONFLICT(organization_id, code) DO UPDATE SET
            display_name = excluded.display_name,
            description = excluded.description,
            system_role = 1,
            active = 1,
            updated_at = excluded.updated_at
        `).run(memberRoleId, organization.id, timestamp, timestamp);
        const insertPermission = db.prepare(`
          INSERT OR IGNORE INTO farm_role_permissions(role_id, permission_code)
          VALUES (?, ?)
        `);
        for (const permission of permissions) {
          insertPermission.run(memberRoleId, permission.code);
        }
        const members = db.prepare(`
          SELECT id FROM studio_members
          WHERE workspace_id = ? AND role != 'owner'
        `).all(organization.id);
        for (const member of members) {
          db.prepare(`
            UPDATE studio_members
            SET role = 'operator', primary_role_code = 'member'
            WHERE id = ?
          `).run(member.id);
          db.prepare('DELETE FROM farm_member_role_assignments WHERE member_id = ?')
            .run(member.id);
          db.prepare(`
            INSERT INTO farm_member_role_assignments(member_id, role_id, assigned_by, assigned_at)
            VALUES (?, ?, ?, ?)
          `).run(member.id, memberRoleId, organization.owner_user_id, timestamp);
        }
        db.prepare(`
          UPDATE farm_roles SET active = 0, updated_at = ?
          WHERE organization_id = ? AND code NOT IN ('owner', 'member')
        `).run(timestamp, organization.id);
        db.prepare(`
          UPDATE farm_roles SET display_name = '管理员',
            description = '管理成员并使用全部农场功能', updated_at = ?
          WHERE organization_id = ? AND code = 'owner'
        `).run(timestamp, organization.id);
      }
    },
  },
  {
    version: 16,
    description: 'immutable farm audit trail with actor and summary snapshots',
    up(db) {
      const columns = new Set(
        db.prepare('PRAGMA table_info(farm_audit_logs)').all().map((row) => row.name),
      );
      for (const [name, type] of [
        ['client_event_id', 'TEXT'],
        ['actor_display_name', 'TEXT'],
        ['actor_identity', 'TEXT'],
        ['summary', 'TEXT'],
      ]) {
        if (!columns.has(name)) {
          db.exec(`ALTER TABLE farm_audit_logs ADD COLUMN ${name} ${type};`);
        }
      }
      db.exec(`
        UPDATE farm_audit_logs
        SET actor_display_name = COALESCE(
              actor_display_name,
              (SELECT display_name FROM users WHERE users.id = farm_audit_logs.actor_user_id),
              '系统'
            ),
            actor_identity = COALESCE(
              actor_identity,
              CASE
                WHEN EXISTS(
                  SELECT 1 FROM studio_members
                  WHERE studio_members.id = farm_audit_logs.actor_member_id
                    AND studio_members.role != 'owner'
                ) THEN 'member'
                WHEN actor_user_id IS NOT NULL THEN 'administrator'
                ELSE 'system'
              END
            );
        CREATE UNIQUE INDEX IF NOT EXISTS farm_audit_logs_client_event_idx
          ON farm_audit_logs(organization_id, client_event_id)
          WHERE client_event_id IS NOT NULL;
        CREATE TRIGGER IF NOT EXISTS farm_audit_logs_no_update
        BEFORE UPDATE ON farm_audit_logs
        BEGIN
          SELECT RAISE(ABORT, 'farm audit history is immutable');
        END;
        CREATE TRIGGER IF NOT EXISTS farm_audit_logs_no_delete
        BEFORE DELETE ON farm_audit_logs
        BEGIN
          SELECT RAISE(ABORT, 'farm audit history is immutable');
        END;
        CREATE TRIGGER IF NOT EXISTS studio_audit_events_no_update
        BEFORE UPDATE ON studio_audit_events
        BEGIN
          SELECT RAISE(ABORT, 'studio audit history is immutable');
        END;
        CREATE TRIGGER IF NOT EXISTS studio_audit_events_no_delete
        BEFORE DELETE ON studio_audit_events
        BEGIN
          SELECT RAISE(ABORT, 'studio audit history is immutable');
        END;
      `);
    },
  },
  {
    version: 17,
    description: 'support codes and public co-creation thank-you wall',
    up(db) {
      db.exec(`
        CREATE TABLE IF NOT EXISTS support_codes (
          code_hash TEXT PRIMARY KEY,
          tier TEXT NOT NULL DEFAULT '同行支持',
          display_label TEXT,
          created_at TEXT NOT NULL,
          redeemed_by TEXT REFERENCES users(id) ON DELETE SET NULL,
          redeemed_at TEXT
        );
        CREATE INDEX IF NOT EXISTS support_codes_redeemed_idx
          ON support_codes(redeemed_at, created_at DESC);
        CREATE TABLE IF NOT EXISTS support_wall_entries (
          id TEXT PRIMARY KEY,
          code_hash TEXT NOT NULL UNIQUE REFERENCES support_codes(code_hash) ON DELETE CASCADE,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          display_name TEXT NOT NULL,
          handle TEXT NOT NULL,
          avatar_url TEXT,
          note TEXT,
          tier TEXT NOT NULL,
          redeemed_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS support_wall_entries_redeemed_idx
          ON support_wall_entries(redeemed_at DESC, id DESC);
      `);
    },
  },
  {
    version: 18,
    description: 'allow anonymous support wall claims',
    up(db) {
      const columns = db.prepare('PRAGMA table_info(support_wall_entries)').all();
      const userColumn = columns.find((column) => column.name === 'user_id');
      // Fresh databases created with the corrected migration are already
      // nullable; this guard keeps the migration safe to replay.
      if (!userColumn || Number(userColumn.notnull) === 0) return;
      db.exec(`
        CREATE TABLE support_wall_entries_v18 (
          id TEXT PRIMARY KEY,
          code_hash TEXT NOT NULL UNIQUE REFERENCES support_codes(code_hash) ON DELETE CASCADE,
          user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
          display_name TEXT NOT NULL,
          handle TEXT NOT NULL,
          avatar_url TEXT,
          note TEXT,
          tier TEXT NOT NULL,
          redeemed_at TEXT NOT NULL
        );
        INSERT INTO support_wall_entries_v18(
          id, code_hash, user_id, display_name, handle, avatar_url,
          note, tier, redeemed_at
        )
        SELECT id, code_hash, user_id, display_name, handle, avatar_url,
          note, tier, redeemed_at
        FROM support_wall_entries;
        DROP TABLE support_wall_entries;
        ALTER TABLE support_wall_entries_v18 RENAME TO support_wall_entries;
        CREATE INDEX IF NOT EXISTS support_wall_entries_redeemed_idx
          ON support_wall_entries(redeemed_at DESC, id DESC);
      `);
    },
  },
  {
    version: 19,
    description: 'personal inventory snapshots for account-scoped desktop/mobile sync',
    up(db) {
      db.exec(`
        CREATE TABLE IF NOT EXISTS personal_inventory_snapshots (
          user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
          revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
          records_json TEXT NOT NULL DEFAULT '[]',
          updated_at TEXT
        );
        CREATE INDEX IF NOT EXISTS personal_inventory_snapshots_updated_idx
          ON personal_inventory_snapshots(updated_at DESC);
      `);
    },
  },
  {
    version: 20,
    description: 'desktop-compatible personal material catalog in inventory snapshots',
    up(db) {
        const columns = db.prepare('PRAGMA table_info(personal_inventory_snapshots)').all();
        if (!columns.some((column) => column.name === 'catalog_json')) {
          db.exec(
            "ALTER TABLE personal_inventory_snapshots "
            + "ADD COLUMN catalog_json TEXT NOT NULL DEFAULT '[]'",
          );
        }
    },
  },
  {
    version: 21,
    description: 'personal inventory deletion tombstones',
    up(db) {
      const columns = db.prepare('PRAGMA table_info(personal_inventory_snapshots)').all();
      if (!columns.some((column) => column.name === 'deleted_json')) {
        db.exec(
          "ALTER TABLE personal_inventory_snapshots "
          + "ADD COLUMN deleted_json TEXT NOT NULL DEFAULT '{}'",
        );
      }
    },
  },
  {
    version: 22,
    description: 'personal inventory RFID tag ownership claims',
    up(db) {
      // A physical CUID/FUID is reusable across spool cycles, but it must not
      // silently move between accounts.  Keep the claim separate from the
      // snapshot so an account cannot release ownership by uploading an empty
      // or stale snapshot.
      db.exec(`
        CREATE TABLE IF NOT EXISTS personal_inventory_tag_claims (
          tag_uid TEXT PRIMARY KEY,
          owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          first_seen_at TEXT NOT NULL,
          last_seen_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS personal_inventory_tag_claims_owner_idx
          ON personal_inventory_tag_claims(owner_id, last_seen_at DESC);
      `);
    },
  },
  {
    version: 23,
    description: 'personal inventory immutable event ledger',
    up(db) {
      const columns = db.prepare('PRAGMA table_info(personal_inventory_snapshots)').all();
      if (!columns.some((column) => column.name === 'events_json')) {
        db.exec(
          "ALTER TABLE personal_inventory_snapshots "
          + "ADD COLUMN events_json TEXT NOT NULL DEFAULT '[]'",
        );
      }
    },
  },
  {
    version: 24,
    description: 'paged personal inventory event outbox',
    up(db) {
      db.exec(`
        CREATE TABLE personal_inventory_events (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          event_uid TEXT NOT NULL COLLATE NOCASE,
          inventory_uid TEXT NOT NULL COLLATE NOCASE,
          event_json TEXT NOT NULL,
          UNIQUE(user_id, event_uid)
        );
        CREATE INDEX personal_inventory_events_cursor_idx
          ON personal_inventory_events(user_id, sequence);
        CREATE INDEX personal_inventory_events_spool_idx
          ON personal_inventory_events(user_id, inventory_uid, sequence);
      `);
      const insert = db.prepare(`INSERT OR IGNORE INTO personal_inventory_events
        (user_id, event_uid, inventory_uid, event_json) VALUES (?, ?, ?, ?)`);
      for (const row of db.prepare('SELECT user_id, events_json FROM personal_inventory_snapshots').all()) {
        const events = JSON.parse(row.events_json || '[]');
        if (!Array.isArray(events)) throw new Error('personal inventory events are corrupted');
        for (const event of events) {
          insert.run(row.user_id, event.eventUid, event.inventoryUid, JSON.stringify(event));
        }
      }
    },
  },
  {
    version: 25,
    description: 'account-scoped printer fault notifications and read-only mobile leases',
    up(db) {
      db.exec(`
        CREATE TABLE printer_fault_sequences(sequence INTEGER PRIMARY KEY AUTOINCREMENT);
        CREATE TABLE personal_printer_faults(
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          event_uid TEXT NOT NULL, sequence INTEGER NOT NULL, event_json TEXT NOT NULL,
          PRIMARY KEY(user_id,event_uid));
        CREATE INDEX personal_printer_faults_cursor ON personal_printer_faults(user_id,sequence);
        CREATE TABLE printer_fault_monitor_leases(
          token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          expires_at TEXT NOT NULL);
      `);
    },
  },
  {
    version: 26,
    description: 'account-owned device workbenches and independent maintenance ledger',
    up(db) {
      db.exec(`
        CREATE TABLE personal_devices(
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          printer_key TEXT NOT NULL, device_token TEXT NOT NULL UNIQUE,
          snapshot_json TEXT NOT NULL, received_at TEXT NOT NULL,
          camera_url TEXT, archived INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(user_id,printer_key));
        CREATE TABLE personal_device_maintenance(
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id TEXT NOT NULL, printer_key TEXT NOT NULL,
          event_uid TEXT NOT NULL, event_json TEXT NOT NULL,
          UNIQUE(user_id,event_uid),
          FOREIGN KEY(user_id,printer_key) REFERENCES personal_devices(user_id,printer_key) ON DELETE CASCADE);
        CREATE INDEX personal_device_maintenance_cursor
          ON personal_device_maintenance(user_id,printer_key,sequence);
      `);
    },
  },
  {
    version: 27,
    description: 'durable reusable material-card stock receipt identities',
    up(db) {
      db.exec(`
        CREATE TABLE personal_stock_receipt_items(
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          receipt_uid TEXT NOT NULL, item_index INTEGER NOT NULL,
          inventory_uid TEXT NOT NULL, source_tag_uid TEXT NOT NULL,
          source_tag_type TEXT NOT NULL, quantity INTEGER NOT NULL,
          created_at TEXT NOT NULL,
          PRIMARY KEY(user_id,receipt_uid,item_index),
          UNIQUE(user_id,inventory_uid));
      `);
    },
  },
];

function stableScalar(value) {
  const text = String(value ?? '').trim();
  if (text.length === 0) return '';

  // Dart's num.tryParse keeps integer and floating-point syntax distinct:
  // `1` becomes `1`, while `1.0` becomes `1.0`. Preserve that distinction so
  // the Node and Dart canonical byte streams remain identical.
  if (/^[+-]?\d+$/.test(text)) {
    const negative = text.startsWith('-');
    const digits = text.replace(/^[+-]/, '').replace(/^0+(?=\d)/, '');
    return `${negative ? '-' : ''}${digits}`;
  }
  if (/^[+-]?(?:\d+\.\d*|\.\d+)(?:e[+-]?\d+)?$/i.test(text)
      || /^[+-]?\d+e[+-]?\d+$/i.test(text)) {
    const parsed = Number(text);
    if (Number.isFinite(parsed)) {
      if (Object.is(parsed, -0)) return text.includes('.') ? '-0.0' : '0';
      const normalized = parsed.toString();
      return Number.isInteger(parsed) ? `${normalized}.0` : normalized;
    }
  }
  return text;
}

function sortedUniqueStrings(values) {
  if (!Array.isArray(values)) return [];
  return [...new Set(values.map((value) => String(value).trim()).filter(Boolean))].sort();
}

function canonicalParamGroups(rawParams) {
  const source = rawParams && typeof rawParams === 'object' && !Array.isArray(rawParams)
    ? rawParams
    : {};
  const result = {};
  for (const groupName of Object.keys(source).sort()) {
    const rawGroup = source[groupName];
    if (!rawGroup || typeof rawGroup !== 'object' || Array.isArray(rawGroup)) continue;
    const group = {};
    for (const key of Object.keys(rawGroup).sort()) {
      group[key] = stableScalar(rawGroup[key]);
    }
    result[groupName] = group;
  }
  return result;
}

/**
 * Produce the exact schema-v2 canonical JSON used by PresetFingerprintService.
 * Display metadata (name, author, counters, timestamps, paths and community
 * identifiers) is intentionally excluded.
 */
export function canonicalPresetJson(presetJson) {
  const decoded = typeof presetJson === 'string' ? JSON.parse(presetJson) : presetJson;
  if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)) {
    throw new TypeError('preset JSON must decode to an object');
  }
  const root = decoded.preset && typeof decoded.preset === 'object' && !Array.isArray(decoded.preset)
    ? decoded.preset
    : decoded;
  const canonical = {
    compatiblePrinters: sortedUniqueStrings(root.compatiblePrinters),
    inherits: String(root.inherits ?? 'fdm_process_common'),
    material: String(root.material ?? ''),
    params: canonicalParamGroups(root.params),
    plateType: String(root.plateType ?? ''),
    scene: String(root.scene ?? ''),
  };
  return JSON.stringify(canonical, null, 2);
}

/**
 * Calculate the stable schema-v2 preset content hash shared with Dart.
 */
export function contentHashOf(presetJson) {
  return createHash('sha256').update(canonicalPresetJson(presetJson), 'utf8').digest('hex');
}

/**
 * 在给定数据库上执行所有未应用的迁移。
 *
 * 幂等：已应用的迁移跳过，未应用的按 version 升序在事务中执行。
 * 任一迁移失败则回滚当前迁移事务并抛出，已成功应用的迁移保持不变。
 */
export function runMigrations(database) {
  if (!(database instanceof DatabaseSync)) {
    throw new TypeError('runMigrations expects a DatabaseSync instance');
  }

  // 1. 确保 community_schema_migrations 表存在（自举）。
  database.exec(`
    CREATE TABLE IF NOT EXISTS community_schema_migrations (
      version INTEGER PRIMARY KEY,
      description TEXT NOT NULL,
      applied_at TEXT NOT NULL
    );
  `);

  // 2. 查询已应用的版本。
  const applied = new Set(
    database.prepare('SELECT version FROM community_schema_migrations').all()
      .map((row) => row.version),
  );

  // 3. 按 version 升序应用未应用的迁移。
  const pending = MIGRATIONS.filter((m) => !applied.has(m.version));
  if (pending.length === 0) {
    return { applied: [], skipped: MIGRATIONS.map((m) => m.version) };
  }

  const appliedNow = [];
  for (const migration of pending) {
    database.exec('BEGIN IMMEDIATE');
    try {
      migration.up(database);
      database.prepare(
        'INSERT INTO community_schema_migrations(version, description, applied_at) VALUES (?, ?, ?)',
      ).run(migration.version, migration.description, new Date().toISOString());
      database.exec('COMMIT');
      appliedNow.push(migration.version);
    } catch (error) {
      database.exec('ROLLBACK');
      throw new Error(
        `Migration ${migration.version} (${migration.description}) failed: ${error.message}`,
      );
    }
  }

  return { applied: appliedNow, skipped: Array.from(applied) };
}
