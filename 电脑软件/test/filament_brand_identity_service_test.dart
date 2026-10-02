import 'package:consumable_tracker_desktop/core/services/farm_brand_catalog_service.dart';
import 'package:consumable_tracker_desktop/core/services/filament_brand_identity_service.dart';
import 'package:consumable_tracker_desktop/core/utils/brand_logo_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('耗材品牌规范化', () {
    test('拓竹的中英文别名统一为桌面资产规范名', () {
      for (final alias in ['拓竹', 'Bambu', 'bambu lab', 'Bambu-Lab', 'BBL']) {
        expect(FilamentBrandIdentityService.normalize(alias), '拓竹');
      }
    });

    test('eSUN 和易生统一为桌面资产规范名', () {
      for (final alias in ['eSUN', 'ESUN', 'e-sun', '易生']) {
        expect(FilamentBrandIdentityService.normalize(alias), 'eSUN');
      }
      expect(FarmBrandCatalogService.normalize('易生').code, 'esun');
      expect(FarmBrandCatalogService.normalize('易生').label, 'eSUN');
    });

    test('自定义品牌保留文字和大小写，仅清理首尾空白', () {
      expect(
        FilamentBrandIdentityService.normalize('  My Custom Brand  '),
        'My Custom Brand',
      );
      expect(FilamentBrandIdentityService.sameBrand('Bambu Lab', '拓竹'), isTrue);
      expect(FilamentBrandIdentityService.sameBrand('', ''), isFalse);
    });
  });

  group('品牌图片解析', () {
    test('拓竹所有规范别名解析到同一图片', () {
      for (final alias in ['拓竹', 'Bambu', 'Bambu Lab']) {
        expect(
          BrandLogoUtils.resolveAsset(alias),
          'assets/images/brands/拓竹.png',
        );
      }
    });

    test('eSUN 和易生解析到现有 eSUN 图片', () {
      for (final alias in ['eSUN', 'ESUN', '易生']) {
        expect(
          BrandLogoUtils.resolveAsset(alias),
          'assets/images/brands/eSUN.png',
        );
      }
    });
  });
}
