import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/chat/models.dart';

void main() {
  group('friendlyUploadError', () {
    test('maps server codes to Russian copy', () {
      expect(friendlyUploadError(GrchatException('BAD_MIME')),
          'Этот тип файлов запрещён.');
      expect(friendlyUploadError(GrchatException('FILE_TOO_BIG')),
          'Файл слишком большой.');
      expect(friendlyUploadError(GrchatException('QUOTA_EXCEEDED')),
          'Квота исчерпана.');
      expect(friendlyUploadError(GrchatException('BAD_FILENAME')),
          'Некорректное имя файла.');
      expect(friendlyUploadError(GrchatException('TOO_MANY_UPLOADS')),
          'Слишком много загрузок, подожди.');
      expect(friendlyUploadError(GrchatException('NOT_MEMBER')),
          'Нет доступа.');
      expect(
          friendlyUploadError(GrchatException('SOMETHING_ELSE')),
          'Не удалось отправить сообщение. Проверьте соединение.');
      expect(friendlyUploadError(StateError('x')),
          'Не удалось отправить сообщение. Проверьте соединение.');
    });
  });

  group('AttachmentIndexEntry', () {
    test('parses and classifies', () {
      final e = AttachmentIndexEntry.fromJson({
        'attachment_id': 'a1',
        'file_id': 'f1',
        'filename': 'pic.png',
        'mime': 'image/png',
        'size_bytes': 10,
        'message_id': 'm1',
        'created_at': '2026-10-06T00:00:00Z',
      });
      expect(e.isImage, isTrue);
      expect(e.isVideo, isFalse);
      expect(
          AttachmentIndexEntry.fromJson({
            'attachment_id': 'a2',
            'mime': 'video/mp4',
          }).isVideo,
          isTrue);
    });
  });
}
