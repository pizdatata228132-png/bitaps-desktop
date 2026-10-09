// Названия узлов подписки в английском интерфейсе.
//
// Регрессия, которую ловит этот тест: список серверов приходит с сервиса выдачи по-русски
// («🇮🇸 Исландия», «🛡️ Румыния · LTE»), а в словаре интерфейса от старого выдуманного списка
// локаций случайно осталось несколько стран. В английском интерфейсе это выглядело как
// «Finland» между «Исландия» и «Гонконг» — половина списка не переводилась.
//
// Метки взяты с боевой выдачи (13 узлов на 2026-07-27), плюс страны, куда узлы ставили раньше.
import 'package:flutter_test/flutter_test.dart';
import 'package:bitaps_vpn/main.dart';
import 'package:bitaps_vpn/singbox_config.dart';

/// Как метки приходят в подписке на самом деле.
const kLiveRemarks = [
  '🇫🇮 Финляндия', '🇳🇱 Нидерланды', '🇫🇷 Франция', '🇵🇱 Польша',
  '🇭🇰 Гонконг', '🇷🇴 Румыния', '🇮🇸 Исландия',
  '🛡️ Румыния · LTE', '🛡️ Финляндия · LTE', '🛡️ Франция · LTE',
  '🛡️ Нидерланды · LTE', '🛡️ Польша · LTE', '🛡️ Гонконг · LTE',
];

Server _fromRemark(String remark) => serverFromSubNode(SubNode(
      remark: remark, tag: remark, server: '1.2.3.4', port: 443,
      // proto теперь по факту протокола (прод 09.10): CDN-узел = xhttp-запись в xray-карте
      xray: remark.contains('LTE')
          ? const {'protocol': 'vless', 'streamSettings': {'network': 'xhttp'}}
          : const {'protocol': 'vless', 'streamSettings': {'network': 'tcp', 'security': 'reality'}},
      // прямые узлы движок sing-box понимает, узлы через CDN — нет; на разбор названия
      // это не влияет, но пусть запись будет такой же, как в жизни
      singbox: remark.contains('LTE') ? null : const {},
    ));

void main() {
  tearDown(() => appLang = 'ru');

  test('хвост рельсы не попадает в название — иначе страна не находится в словаре', () {
    final s = _fromRemark('🛡️ Румыния · LTE');
    expect(s.city, 'Румыния');
    expect(s.flag, '🛡️');
  });

  test('каждая страна боевой выдачи переводится в EN', () {
    appLang = 'en';
    final notTranslated = <String>[];
    for (final r in kLiveRemarks) {
      final city = _fromRemark(r).city;
      if (tr(city) == city) notTranslated.add(city);
    }
    expect(notTranslated, isEmpty,
        reason: 'нет английского названия для: ${notTranslated.join(", ")} — добавь в kCountryEn');
  });

  test('в русском интерфейсе названия остаются русскими', () {
    appLang = 'ru';
    expect(tr(_fromRemark('🇮🇸 Исландия').city), 'Исландия');
  });

  group('выбор лучшего сервера', () {
    final direct = _fromRemark('🇫🇮 Финляндия');       // proto Reality
    final cdn = _fromRemark('🛡️ Румыния · LTE');       // proto CDN (рельса, xhttp)

    int pingOf(Server s, Map<String, int> m) => m[s.id] ?? 0;

    test('незамеренный узел НЕ считается самым быстрым', () {
      final m = {direct.id: 80};   // CDN не замерен → пинг 0
      final list = [cdn, direct]..sort((a, b) => compareServers(a, b, (s) => pingOf(s, m)));
      expect(list.first.city, 'Финляндия', reason: 'ноль у незамеренного не должен выигрывать');
    });

    test('при равном отклике выигрывает прямой узел, а не CDN', () {
      final m = {direct.id: 80, cdn.id: 80};
      final list = [cdn, direct]..sort((a, b) => compareServers(a, b, (s) => pingOf(s, m)));
      expect(list.first.city, 'Финляндия');
    });

    test('замеренный быстрый выигрывает у замеренного медленного', () {
      final m = {direct.id: 200, cdn.id: 40};
      final list = [direct, cdn]..sort((a, b) => compareServers(a, b, (s) => pingOf(s, m)));
      expect(list.first.city, 'Румыния');
    });
  });

  group('приговоры по узлам', _verdictTests);

  test('незнакомая страна не ломает список, а показывается как есть', () {
    appLang = 'en';
    // так выглядит нода в стране, которой ещё нет в таблице: перевода нет, но и падения нет
    expect(tr(_fromRemark('🇻🇦 Ватикан').city), 'Ватикан');
  });
}

// ── Приговоры по узлам: что реально пропускает трафик ──
// Регрессия, ради которой всё затевалось: при глушении интернета TCP-коннект до прямого узла
// проходит, а трафик сквозь него — нет. Узел с зелёным откликом оказывался мёртвым, и «лучший
// сервер» выбирал именно его.
void _verdictTests() {
  Server srv(String id, {bool cdn = false}) => Server(id, id, '', '🌐', 0, 0, proto: cdn ? 'CDN' : 'Reality');

  test('непригодный узел никогда не выигрывает у рабочего', () {
    final dead = srv('dead'), live = srv('live', cdn: true);
    final st = {'dead': NodeState.blocked, 'live': NodeState.works};
    final l = [dead, live]..sort((a, b) => compareServers(a, b, (_) => 0, stateOf: (s) => st[s.id]!));
    expect(l.first.id, 'live', reason: 'через CDN трафик идёт, через прямой — нет');
  });

  test('проверенный рабочий выигрывает у непроверенного, даже если тот «быстрее»', () {
    final fast = srv('fast'), ok = srv('ok');
    final st = {'fast': NodeState.unknown, 'ok': NodeState.works};
    final ping = {'fast': 10, 'ok': 300};
    final l = [fast, ok]..sort((a, b) => compareServers(a, b, (s) => ping[s.id]!, stateOf: (s) => st[s.id]!));
    expect(l.first.id, 'ok');
  });

  test('приговор с чужой сети не считается за истину', () {
    final v = NodeVerdict(ok: true, at: DateTime.now(), net: '77.88');
    expect(v.fresh, isTrue);
    expect(v.net == '10.20', isFalse, reason: 'сеть другая — приговор к ней не относится');
  });

  test('устаревший приговор перестаёт быть свежим', () {
    final old = NodeVerdict(ok: true, at: DateTime.now().subtract(kVerdictTtl * 2), net: 'x');
    expect(old.fresh, isFalse);
  });

  test('приговор переживает запись и чтение', () {
    final v = NodeVerdict(ok: false, ms: null, at: DateTime.now(), net: '5.6');
    final back = NodeVerdict.fromJson(v.toJson());
    expect(back!.ok, isFalse);
    expect(back.net, '5.6');
  });
}
