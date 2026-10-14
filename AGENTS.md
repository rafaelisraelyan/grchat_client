# Регламент работы над grchat_client

## 1. Команды (проверены на этой машине)
```
dart analyze lib test                       # должен быть «No issues found!»
C:\src\flutter\bin\flutter.bat test         # сейчас 347/347
C:\src\flutter\bin\flutter.bat build windows --debug `
    --dart-define=GRCHAT_DEV_CA=C:\Users\GR\.grchat_dev\grchat_dev.pem
```
Два окна для живой проверки — отдельными `Start-Process` из
`build\windows\x64\runner\Debug` (не параллельные `flutter run`), логи в
`%TEMP%\opencode\<tag>_<HHmmss>.out|err`.

Стойка серверов (LiveKit + Caddy + java с GRCHAT_SIGN_SEED в env, без секретов
в cmdline):
```
powershell -NoProfile -File %TEMP%\opencode\stack_keys_env.ps1
```
Ожидаемые слушатели: 8443 (TLS сервера), 7880/7881 (LiveKit), 7443 (Caddy/wss).
Maven не в PATH: `C:\Program Files\JetBrains\IntelliJIdea2026.1\plugins\maven\lib\maven3\bin\mvn.cmd`.

Диагностика захвата камеры/микрофона — только по фактам:
`%TEMP%\grchat_desktop.log` (каждая строка несёт `[webrtc pid-N]`), ConsentStore
`HKCU:\...\CapabilityAccessManager\ConsentStore\webcam\NonPackaged` (Start/Stop —
доказательство реального освобождения устройства).

## 2. Ворота приёмки
- `dart analyze lib test` чистый, `flutter test` зелёный — иначе задача не
  закрыта.
- Новое поведение с чистой логикой покрыто тестом (чистые функции в
  `quality_tier.dart`, `media_prefs.dart`, `camera_notice.dart` + группа в
  `test/device_default_test.dart`).
- Живая проверка в двух окнах, если правка касается камеры/микрофона/звонка:
  результат — строки лога, а не «вроде работает».

## 3. Нельзя трогать без явного «да»
- Лестница качества видео (`quality_tier.dart`: тиры, `videoTiers`, пол 1080p60).
- Сервер и подписи конвертов (`grchat-server`, `server_sign.dart`,
  `EnvelopeSigner.java`), seed'ы, ключи.
- Релизная сборка, публикация, версия в `pubspec.yaml`.
- Коммит/пуш — только по отдельному «да» (см. глобальные правила).

## 4. BACKLOG.md — память проекта
Каждая содержательная правка оставляет запись в `BACKLOG.md`:
- что сломано → **факт из лога/измерения**, не гипотеза;
- контракт поведения (§-раздел), который переживёт рефакторинг;
- грабли, чтобы не повторить (плагин, DirectShow, драйверы).
Секции с `§` — ссылочные: `§call-type`, `§remote-mute`, `§switch-camera`,
`§camera-release`, `§dial-camera-walk`, `§plugin-dispose-quirk`.

## 5. Контракты, которые нельзя тихо сломать
- **Грамматика устройств:** и видео, и микрофон выбираются ТОЛЬКО через
  legacy `optional: [{sourceId}]`; `deviceId` для входа игнорируется плагином.
- **§plugin-dispose-quirk:** `track.stop()` выполняет StopCapture, пока трек
  числится в известном стриме. Порядок строго `stop()` → потом `removeTrack()`.
  Обратный порядок = камера горит вечно (доказано ConsentStore без Stop).
- **§camera-release:** выключение камеры в звонке = реальный отпуск устройства
  (`replaceTrack(null)` + stop + removeTrack), а не `track.enabled = false`.
- **§switch-camera:** смена камеры — цикл off → switch → on (пользователь
  подтвердил: драйверы не переключаются на лету). CameraLock непрерывен у
  инстанса. Отказ → авто-возврат прежней камеры, откат сохранённого выбора,
  честный тост.
- **§call-type:** тип звонка определяется `m=video` в оффере. Видеозвонок не
  деградирует в аудио: нет камеры → m-line держит трансивер-пустышка, камера
  подключается позже; такой m-line negotiated recvonly → при attach одна
  ренеготиация.
- **§dial-camera-walk:** на наборе обходим остальные камеры (≤3, физические
  первыми) и сохраняем рабочую; названное устройство не подменяем никогда.
- **§remote-mute:** пир выключил камеру → inbound-счётчики замерли → показываем
  аватар, а не замёрзший кадр.

## 6. Логи — диагностика, а не украшение
- Формат открытия: `camera opened: label=…, requested=WxH@fps,
  source=auto|explicit|walk|fallback, device=<getSettings().deviceId>, real=…`
  (`device` — не эхо; `label` — рандомный id трека).
- Каждый реальный отпуск: `camera released: label=… (<путь>)`.
- Каждая проба: `camera probe [<устройство>] WxH@fps: …` — устройство
  обязательно, иначе в двухоконном логе не разобрать, чья это камера.
- Никогда не печатать секреты; в лог — только факт применения.

## 7. Живая проверка в двух окнах (шаблон)
1. Открыть Broadcast (или другой держатель) → физическая камера отдаёт
   «open ok, no frames» → набор по видео всё равно должен остаться
   видеозвонком, обход обязан найти рабочую камеру.
2. Смена камеры в звонке: цикл, парные `opened/released`, авто-возврат при
   отказе.
3. Завершение звонка и выключение камеры: ConsentStore обязан показать Stop.
4. Пир выключает камеру → у нас аватар через ~6 с, не чёрный кадр.

## 8. Язык и формат отчётов
- По-русски, коротко, с фактами и цифрами из логов; без mojibake и CJK.
- Коммит-сообщения — по-русски, с сутью пачки, а не «fixes».