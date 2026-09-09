// 重新导出 [databaseProvider] 的兼容垫片。
//
// 历史原因：[databaseProvider] 定义在 lib/providers/database_provider.dart，
// 但部分 provider（print_queue_provider / batch_recognition_provider）
// 通过 `import '../data/database/database_provider.dart'` 引用。
// 此垫片让该路径生效，避免修改既有 provider 文件。
export '../../providers/database_provider.dart' show databaseProvider;
