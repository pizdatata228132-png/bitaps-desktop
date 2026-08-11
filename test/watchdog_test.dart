// Watchdog «всегда на связи»: правило «N подряд неудачных проверок = туннель мёртв».
//
// Зачем именно этот тест. Сам watchdog (таймер + verifyConnected) без живого движка не
// воспроизвести, но его РЕШАЮЩЕЕ правило — чистое: единичный сбой сети не должен рвать
// живое подключение (ложный разрыв хуже отсутствия проверки), а подтверждённая серия тишин
// обязана уходить в тот же путь, что и обрыв (fail-state + серия автореконнекта).
import 'package:flutter_test/flutter_test.dart';
import 'package:bitaps_vpn/main.dart';

void main() {
  test('watchdog: разрыв только после kWatchdogMaxFails подряд неудач', () {
    for (var fails = 1; fails < ConnectionController.kWatchdogMaxFails; fails++) {
      expect(ConnectionController.watchdogDrops(fails), isFalse,
          reason: '$fails неудача(и) — ещё не разрыв: единичный сбой сети не рвёт сессию');
    }
    expect(ConnectionController.watchdogDrops(ConnectionController.kWatchdogMaxFails), isTrue,
        reason: 'подтверждённая серия тишин — туннель мёртв, реконнект');
    expect(ConnectionController.watchdogDrops(ConnectionController.kWatchdogMaxFails + 3), isTrue);
  });

  test('watchdog: порог из ТЗ — 3 подряд (каждая неудача это уже два gen204-раунда)', () {
    expect(ConnectionController.kWatchdogMaxFails, 3);
    expect(ConnectionController.kWatchdogInterval, const Duration(seconds: 30));
  });
}
