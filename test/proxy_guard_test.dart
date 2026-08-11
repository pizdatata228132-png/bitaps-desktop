// Гарды системного прокси из свежего багханта (CRIT/HIGH/MED) — чистые правила.
//
// Зачем именно этот тест. Сами пути через ОС (networksetup/reg/gsettings) без живой системы
// не воспроизвести, поэтому решающие правила вынесены в чистые функции SystemProxy и здесь
// зафиксированы:
//   • snapshotNeeded — снимок настроек делаем, только если текущий прокси НЕ наш; иначе при
//     реконнекте из блокировки снимок с реальными настройками пользователя затирался нашим
//     мёртвым 127.0.0.1:<порт> и _restore() вписывал его обратно — «нет интернета» (CRIT);
//   • ownPortsMatch/parseOwnPorts — «наш» прокси определяется по персистированным портам,
//     а не по голому 127.0.0.1 (Happ и прочие на localhost — не трогаем) (MED);
//   • decideStaleCleanup с instanceLockHeld — при держащейся блокировке одной копии живой
//     порт движка это сирота, а не другая копия: чистим, а не keptAlive (MED).
import 'package:flutter_test/flutter_test.dart';
import 'package:bitaps_vpn/desktop_engine.dart';

void main() {
  group('snapshotNeeded — снимок только поверх ЧУЖИХ настроек', () {
    test('текущий прокси наш (реконнект из блокировки) → снимок НЕ делаем', () {
      expect(SystemProxy.snapshotNeeded(true), isFalse,
          reason: 'иначе снимок с реальными настройками затирался нашим мёртвым прокси');
    });
    test('текущий прокси чужой/отсутствует → снимаем, чтобы вернуть как было', () {
      expect(SystemProxy.snapshotNeeded(false), isTrue);
    });
  });

  group('parseOwnPorts / ownPortsMatch — «наш» по персистированным портам', () {
    test('разбор строки портов', () {
      expect(SystemProxy.parseOwnPorts('40001,40002'), {40001, 40002});
      expect(SystemProxy.parseOwnPorts(''), isNull);
      expect(SystemProxy.parseOwnPorts(null), isNull);
      expect(SystemProxy.parseOwnPorts('40001,бито'), isNull, reason: 'битой записи не доверяем');
      expect(SystemProxy.parseOwnPorts('0,99999'), isNull, reason: 'порты вне диапазона — не доверяем');
    });

    test('без записи (сессия старой версии) — прежнее поведение: localhost = наш', () {
      expect(SystemProxy.ownPortsMatch(null, {10808}), isTrue);
      expect(SystemProxy.ownPortsMatch({}, {10808}), isTrue);
    });

    test('с записью: наш только при пересечении портов', () {
      final own = SystemProxy.parseOwnPorts('40001,40002');
      expect(SystemProxy.ownPortsMatch(own, {40002}), isTrue);
      expect(SystemProxy.ownPortsMatch(own, {10808}), isFalse,
          reason: 'Happ на 127.0.0.1:10808 — чужой работающий прокси, гасить нельзя');
    });
  });

  group('decideStaleCleanup — instance-lock против сироты', () {
    test('живой порт + блокировка у нас → сирота: чистим, а не keptAlive', () {
      expect(
        SystemProxy.decideStaleCleanup(proxyIsOurs: true, engineAlive: true, instanceLockHeld: true),
        StaleCleanup.cleaned,
        reason: 'вторая копия вышла бы до уборки — живой порт это осиротевший движок прошлой сессии');
    });

    test('живой порт без блокировки (порт занят чужим) — прежний консерватизм keptAlive', () {
      expect(
        SystemProxy.decideStaleCleanup(proxyIsOurs: true, engineAlive: true, instanceLockHeld: false),
        StaleCleanup.keptAlive);
    });

    test('прежние ветки не изменились', () {
      expect(SystemProxy.decideStaleCleanup(proxyIsOurs: false, engineAlive: true), StaleCleanup.nothing);
      expect(SystemProxy.decideStaleCleanup(proxyIsOurs: false, engineAlive: false), StaleCleanup.nothing);
      expect(SystemProxy.decideStaleCleanup(proxyIsOurs: true, engineAlive: false), StaleCleanup.cleaned);
    });
  });

  group('macCleanupServices — уборка по ВСЕМ сервисам (аудит M2)', () {
    test('полный список системы важнее суженного looksOurs', () {
      expect(SystemProxy.macCleanupServices(['Wi-Fi', 'Ethernet'], ['Wi-Fi']), ['Wi-Fi', 'Ethernet'],
          reason: 'снятие только с первого совпадения оставляло протухший прокси на втором сервисе');
    });
    test('системный список не прочитался — суженный лучше, чем ничего', () {
      expect(SystemProxy.macCleanupServices(const [], ['Wi-Fi']), ['Wi-Fi']);
      expect(SystemProxy.macCleanupServices(const [], const []), isEmpty);
    });
  });

  group('parseOwnEnginePidsPosix — добивка сироты строго нашего бинаря (аудит M1)', () {
    const out = '412 /Applications/bitaps VPN.app/Contents/MacOS/xray run -c stdin:\n'
        '588 /usr/local/bin/xray\n'
        '60012 /Applications/bitaps VPN.app/Contents/MacOS/xray\n'
        'битая строка\n';
    test('берём только полный путь нашего exeDir', () {
      expect(
        SystemProxy.parseOwnEnginePidsPosix(out, '/Applications/bitaps VPN.app/Contents/MacOS'),
        [412, 60012],
        reason: 'чужой xray из /usr/local добивать нельзя');
    });
    test('хвостовой слэш exeDir не мешает, чужих нет — пусто', () {
      expect(SystemProxy.parseOwnEnginePidsPosix(out, '/Applications/bitaps VPN.app/Contents/MacOS/'),
          [412, 60012]);
      expect(SystemProxy.parseOwnEnginePidsPosix(out, '/opt/other'), isEmpty);
      expect(SystemProxy.parseOwnEnginePidsPosix('', '/Applications/x'), isEmpty);
    });
  });
}
