import 'package:archive/archive.dart';
import 'package:consumable_tracker_desktop/core/utils/zip_safety.dart';
import 'package:flutter_test/flutter_test.dart';

Archive archiveWithSizes(List<int> sizes) {
  final archive = Archive();
  for (var i = 0; i < sizes.length; i++) {
    archive.addFile(ArchiveFile('entry-$i', sizes[i], <int>[]));
  }
  return archive;
}

void main() {
  test('accepts a normal archive within all resource budgets', () {
    expect(isSafe3mfArchive(archiveWithSizes([1024, 2048])), isTrue);
  });

  test('rejects an entry whose declared expanded size is too large', () {
    expect(
      isSafe3mfArchive(archiveWithSizes([max3mfEntryBytes + 1])),
      isFalse,
    );
  });

  test('rejects an archive whose declared total expansion is too large', () {
    expect(
      isSafe3mfArchive(
        archiveWithSizes([
          max3mfEntryBytes,
          max3mfEntryBytes,
          max3mfEntryBytes,
          max3mfEntryBytes + 1,
        ]),
      ),
      isFalse,
    );
  });

  test('rejects an archive with too many members', () {
    expect(
      isSafe3mfArchive(
        archiveWithSizes(List<int>.filled(max3mfEntryCount + 1, 1)),
      ),
      isFalse,
    );
  });
}
