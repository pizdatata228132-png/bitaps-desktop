// Пин libXray в tools/fetch-libxray.sh (аудит M5): версия и sha256 закреплены, артефакт
// проверяется ДО распаковки.
//
// Зачем именно этот тест. Скрипт тянет нативный фреймворк, которому приложение доверяет ВЕСЬ
// трафик; «latest» + отсутствие проверки хэша — это подмена движка одной скомпрометированной
// выдачей GitHub/CDN. Здесь фиксируем контракт скрипта: дефолт — конкретный тег (не latest),
// рядом валидный sha256, непиновая версия требует явного хэша, проверка идёт до unzip.
// Хэш в тесте не зашит (он меняется с перевыпуском пина) — проверяются форма и механика.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('tools/fetch-libxray.sh').readAsStringSync();

  test('версия закреплена конкретным тегом, «latest» в дефолте нет', () {
    final m = RegExp(r'^LIBXRAY_VERSION="(v\d+\.\d+\.\d+)"$', multiLine: true).firstMatch(src);
    expect(m, isNotNull, reason: 'LIBXRAY_VERSION обязан быть пином вида v26.7.28');
    expect(src.contains('releases/latest'), isFalse,
        reason: 'дефолт на latest = доверие сети без пина (ровно то, что закрывает M5)');
  });

  test('рядом валидный sha256 артефакта (64 hex)', () {
    final m = RegExp(r'^LIBXRAY_SHA256="([0-9a-f]{64})"', multiLine: true).firstMatch(src);
    expect(m, isNotNull, reason: 'LIBXRAY_SHA256 обязан быть 64-hex хэшем закреплённого zip');
  });

  test('проверка хэша идёт до распаковки, непиновая версия требует явного хэша', () {
    expect(src.contains('shasum -a 256 -c -') || src.contains('sha256sum -c -'), isTrue,
        reason: 'скачанный zip обязан сверяться с хэшем');
    expect(src.contains('LIBXRAY_SHA256_OVERRIDE'), isTrue,
        reason: 'другую версию — только с явным хэшем, молча сети не доверяем');
    final iCheck = src.indexOf('shasum -a 256 -c -');
    final iUnzip = src.indexOf('unzip');
    expect(iCheck, greaterThan(-1));
    expect(iCheck, lessThan(iUnzip), reason: 'проверка после распаковки бессмысленна');
  });
}
