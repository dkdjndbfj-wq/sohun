import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// 图片本地存储工具。
///
/// 把用户选择/拖入的图片复制到应用数据目录下的 images/ 子目录，
/// 返回相对路径（如 'presets/abc123.jpg'）。
/// 读取时用 [getFullPath] 拼接成绝对路径。
class ImageStorage {
  ImageStorage._();

  static const String _imagesDirName = 'images';

  /// 获取 images 目录绝对路径
  static Future<Directory> get imagesDir async {
    final appData = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appData.path, _imagesDirName));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 保存图片到应用数据目录。
  /// [sourcePath] 是用户选择的图片的绝对路径。
  /// [subDir] 是子目录（如 'presets'、'avatars'），用于分类管理。
  /// 返回相对路径（如 'presets/abc123.jpg'），用于存入数据库。
  static Future<String> saveImage({
    required String sourcePath,
    required String subDir,
  }) async {
    final baseDir = await imagesDir;
    final targetDir = Directory(_resolveInside(baseDir.path, subDir));
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    final ext = p.extension(sourcePath).toLowerCase();
    final fileName = '${DateTime.now().millisecondsSinceEpoch}$ext';
    final targetPath = p.join(targetDir.path, fileName);

    // 复制文件
    final sourceFile = File(sourcePath);
    await sourceFile.copy(targetPath);

    // 返回相对路径（相对于 images 目录）
    return p.join(subDir, fileName);
  }

  /// 把相对路径转为绝对路径。
  /// [relativePath] 是 saveImage 返回的相对路径。
  static Future<String> getFullPath(String relativePath) async {
    final baseDir = await imagesDir;
    return _resolveInside(baseDir.path, relativePath);
  }

  /// 同步版本：把相对路径转为绝对路径（已缓存的 imagesDir）。
  /// 需要先调用一次 [imagesDir] 确保目录存在。
  static String getFullPathSync(String relativePath, String imagesBasePath) {
    return _resolveInside(imagesBasePath, relativePath);
  }

  /// 删除图片。
  static Future<void> deleteImage(String relativePath) async {
    final baseDir = await imagesDir;
    final file = File(_resolveInside(baseDir.path, relativePath));
    if (file.existsSync()) {
      await file.delete();
    }
  }

  /// 检查相对路径对应的文件是否存在。
  static Future<bool> exists(String relativePath) async {
    final baseDir = await imagesDir;
    final file = File(_resolveInside(baseDir.path, relativePath));
    return file.existsSync();
  }

  static String _resolveInside(String basePath, String relativePath) {
    final value = relativePath.trim();
    if (value.isEmpty || p.isAbsolute(value)) {
      throw ArgumentError.value(relativePath, 'relativePath');
    }
    final normalizedBase = p.normalize(p.absolute(basePath));
    final resolved = p.normalize(p.join(normalizedBase, value));
    if (!p.isWithin(normalizedBase, resolved)) {
      throw ArgumentError.value(relativePath, 'relativePath');
    }
    return resolved;
  }
}
