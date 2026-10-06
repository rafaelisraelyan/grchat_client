import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/update/update_service.dart';

/// The release gate: what counts as newer, and what a tag parses to.
/// A wrong answer here either hides a release or pushes a downgrade through
/// the auto-install path, so the table is explicit.
void main() {
  group('release tag parsing', () {
    test('stable and beta tags yield dotted versions', () {
      expect(UpdateCenter.numbersForTest('v1.1.1-beta.1'), '1.1.1');
      expect(UpdateCenter.numbersForTest('v1.1.0-beta.1'), '1.1.0');
      expect(UpdateCenter.numbersForTest('v2.0.0'), '2.0.0');
      expect(UpdateCenter.numbersForTest('garbage'), '0.0.0');
      expect(UpdateCenter.numbersForTest(''), '0.0.0');
    });
  });

  group('newer-than check', () {
    test('patch and minor bumps are newer', () {
      expect(UpdateCenter.isNewerForTest('1.1.1', '1.1.0'), isTrue);
      expect(UpdateCenter.isNewerForTest('1.2.0', '1.1.9'), isTrue);
      expect(UpdateCenter.isNewerForTest('2.0.0', '1.9.9'), isTrue);
    });

    test('same or older is not newer — never reinstall, never downgrade', () {
      expect(UpdateCenter.isNewerForTest('1.1.0', '1.1.0'), isFalse);
      expect(UpdateCenter.isNewerForTest('1.1.0', '1.1.1'), isFalse);
      expect(UpdateCenter.isNewerForTest('1.1.10', '1.1.9'), isTrue,
          reason: 'numeric, not lexicographic: 10 > 9');
      expect(UpdateCenter.isNewerForTest('1.1.9', '1.1.10'), isFalse);
    });
  });
}
