import 'dart:io';

import 'package:archive/archive.dart';

/// Resource budgets for user-selected 3MF/ZIP containers.
///
/// ZipDecoder keeps compressed entries lazy, so checking the central-directory
/// sizes immediately after decoding prevents an entry from being expanded by a
/// later `.content` access.
const max3mfInputBytes = 64 * 1024 * 1024;
const max3mfEntryCount = 512;
const max3mfEntryBytes = 64 * 1024 * 1024;
const max3mfExpandedBytes = 256 * 1024 * 1024;

Future<bool> isSafe3mfFile(
  File file, {
  int maxInputBytes = max3mfInputBytes,
}) async {
  try {
    return await file.length() <= maxInputBytes;
  } on FileSystemException {
    return false;
  }
}

bool isSafe3mfArchive(
  Archive archive, {
  bool allowLargeModelEntries = false,
}) {
  if (archive.length > max3mfEntryCount) return false;
  var expandedBytes = 0;
  for (final entry in archive) {
    final isModelEntry = entry.name.startsWith('3D/Objects/');
    if (entry.size < 0 ||
        (!allowLargeModelEntries && entry.size > max3mfEntryBytes) ||
        (allowLargeModelEntries &&
            isModelEntry &&
            entry.size > 2 * 1024 * 1024 * 1024)) {
      return false;
    }
    // Model meshes are kept file-backed and are never expanded by the
    // metadata inspector. Exclude them from the small metadata expansion
    // budget while retaining a strict bound for every other entry.
    if (!isModelEntry) {
      expandedBytes += entry.size;
      if (expandedBytes > max3mfExpandedBytes) return false;
    }
  }
  return true;
}
