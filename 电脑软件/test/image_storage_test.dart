import 'dart:io';

import 'package:consumable_tracker_desktop/core/utils/image_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('local image paths stay inside the application image directory', () {
    final base = p.join(Directory.systemTemp.path, 'app-images');
    final resolved = ImageStorage.getFullPathSync(
      p.join('presets', 'preview.png'),
      base,
    );

    expect(p.isWithin(p.absolute(base), resolved), isTrue);
    expect(
      () => ImageStorage.getFullPathSync(
        p.join('..', 'outside.png'),
        base,
      ),
      throwsArgumentError,
    );
    expect(
      () => ImageStorage.getFullPathSync(
        p.join(p.rootPrefix(p.absolute(base)), 'outside.png'),
        base,
      ),
      throwsArgumentError,
    );
  });
}
