import 'package:consumable_tracker_desktop/core/utils/public_image_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('只接受无凭据、无片段的公网 HTTPS 图片地址', () {
    expect(
      parsePublicHttpsImageUrl(
        'https://cdn.example.com/avatar/a.png?width=128',
        trustedOrigin: Uri.parse('https://cdn.example.com/community'),
      )?.toString(),
      'https://cdn.example.com/avatar/a.png?width=128',
    );

    for (final value in <String>[
      'http://cdn.example.com/a.png',
      'https://localhost/a.png',
      'https://printer.local/a.png',
      'https://127.0.0.1/a.png',
      'https://127.1/a.png',
      'https://10.0.0.1/a.png',
      'https://172.16.0.1/a.png',
      'https://192.168.1.1/a.png',
      'https://169.254.169.254/latest/meta-data',
      'https://[::1]/a.png',
      'https://[fe80::1]/a.png',
      'https://[fd00::1]/a.png',
      'https://user:password@cdn.example.com/a.png',
      'https://cdn.example.com/a.png#fragment',
      'javascript:alert(1)',
      'not a url',
    ]) {
      expect(
        parsePublicHttpsImageUrl(
          value,
          trustedOrigin: Uri.parse('https://cdn.example.com/community'),
        ),
        isNull,
        reason: value,
      );
    }

    expect(
      parsePublicHttpsImageUrl(
        'https://cdn.example.com/a.png',
      ),
      isNull,
    );
    expect(
      parsePublicHttpsImageUrl(
        'https://other.example.com/a.png',
        trustedOrigin: Uri.parse('https://cdn.example.com/community'),
      ),
      isNull,
    );
  });

  test('本地图片引用与带 scheme/authority 的远程引用严格区分', () {
    expect(isLocalImageReference(r'images\preview.png'), isTrue);
    expect(isLocalImageReference('images/preview.png'), isTrue);
    expect(isLocalImageReference('https://cdn.example.com/a.png'), isFalse);
    expect(isLocalImageReference('//cdn.example.com/a.png'), isFalse);
  });
}
