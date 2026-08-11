// Hot-switch сервера без разрыва VPN + одновременность замера флота (lanes).
//
// Зачем именно этот тест. Плавная смена сервера (TunnelEngine.hotSwitch) поднимает второй
// процесс движка и переписывает системный прокси только после verify — ошибка в решающем
// правиле отдаёт трафик непроверенному узлу (или роняет живой туннель на гонке с отменой).
// Без живого движка прогон не воспроизвести, поэтому фиксируем чистое правило коммита и
// таблицу lanes (Android-параллелизм ограничен осознанно — см. pingLanes).
import 'package:flutter_test/flutter_test.dart';
import 'package:bitaps_vpn/engine.dart';

void main() {
  group('hotSwitchCommits — прокси переносим только на подтверждённый кандидат', () {
    test('verify пройден + поколение не сменилось → коммит', () {
      expect(TunnelEngine.hotSwitchCommits(verified: true, epochBefore: 7, epochNow: 7), isTrue);
    });

    test('verify провален → НЕ коммитим: старый туннель остаётся', () {
      expect(TunnelEngine.hotSwitchCommits(verified: false, epochBefore: 7, epochNow: 7), isFalse,
          reason: 'прокси на мёртвый кандидат = «нет интернета» — только откат');
    });

    test('поколение сменилось за прогон (отмена/обрыв/новый connect) → НЕ коммитим', () {
      expect(TunnelEngine.hotSwitchCommits(verified: true, epochBefore: 7, epochNow: 8), isFalse,
          reason: 'позднее завершение не должно перетягивать прокси у нового состояния');
      expect(TunnelEngine.hotSwitchCommits(verified: false, epochBefore: 7, epochNow: 8), isFalse);
    });
  });

  group('pingLanes — одновременность замера флота', () {
    test('десктоп 6 полос, Android 2 (не 4 и не 1)', () {
      expect(TunnelEngine.pingLanes(false), 6);
      expect(TunnelEngine.pingLanes(true), 2,
          reason: 'пробы плагина делят синглтон V2rayCoreManager с живым VpnService: '
              'потокобезопасность go-lib не гарантирована, а нативный сбой убил бы подключение');
    });
  });
}
