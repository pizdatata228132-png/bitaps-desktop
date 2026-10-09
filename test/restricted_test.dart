// Режим «ограниченная сеть» (белые списки): классификация пре-флайта, порядок кандидатов
// «рельсы вперёд» и правило автоподхвата рельсы при ручном выборе прямой ноды.
//
// Зачем именно этот тест. В сетях ТСПУ-режима прямые ноды мертвы, а CDN-рельсы живы: если
// порядок перебора оставить прежним, подключение виснет на мёртвых прямых нодах — ровно та
// жалоба владельца. Сам пре-флайт (TCP-коннекты) и цикл кандидатов без живой сети/движка не
// воспроизвести, поэтому тест фиксирует три чистых правила, которыми они руководствуются:
// classifyNetProfile (engine.dart), compareServers cdnFirst (models.dart) и
// ConnectionController.roamRescue (connection.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:bitaps_vpn/engine.dart';
import 'package:bitaps_vpn/main.dart';
import 'package:bitaps_vpn/singbox_config.dart';

// Прямая нода и CDN-рельса в виде строк списка серверов (proto — как в serverFromSubNode).
Server _direct(String id, {int ping = 0}) => Server(id, 'Финляндия', '', '🇫🇮', ping, 0);
Server _relay(String id, {int ping = 0}) => Server(id, 'Нидерланды', '', '🛡️', ping, 0, proto: 'CDN');

void main() {
  group('classifyNetProfile — классификация пре-флайта', () {
    test('прямые мертвы + рельсы живы → restricted', () {
      expect(classifyNetProfile(directAlive: false, cdnAlive: true), NetProfile.restricted);
    });
    test('прямые живы → normal (независимо от рельс)', () {
      expect(classifyNetProfile(directAlive: true, cdnAlive: true), NetProfile.normal);
      expect(classifyNetProfile(directAlive: true, cdnAlive: false), NetProfile.normal);
    });
    test('мертвы все → unknown: лежит весь интернет, а не «белый список»', () {
      expect(classifyNetProfile(directAlive: false, cdnAlive: false), NetProfile.unknown,
          reason: 'перестановка кандидатов при мёртвом интернете ничего не спасёт');
    });
  });

  group('compareServers cdnFirst — порядок кандидатов в restricted', () {
    int pingOf(Server s) => s.ping;

    test('restricted: рельса впереди прямой, даже если у прямой пинг лучше', () {
      final direct = _direct('d', ping: 40);
      final relay = _relay('r', ping: 180);
      expect(compareServers(relay, direct, pingOf, cdnFirst: true), lessThan(0),
          reason: 'в restricted первая попытка обязана идти на рельсу');
      expect(compareServers(direct, relay, pingOf, cdnFirst: true), greaterThan(0));
    });

    test('без cdnFirst порядок прежний: лучший пинг выигрывает', () {
      final direct = _direct('d', ping: 40);
      final relay = _relay('r', ping: 180);
      expect(compareServers(direct, relay, pingOf), lessThan(0));
      expect(compareServers(relay, direct, pingOf), greaterThan(0));
    });

    test('restricted: мёртвая рельса НЕ обгоняет работающую прямую (ранг сильнее)', () {
      final relay = _relay('r', ping: 100);
      final direct = _direct('d', ping: 100);
      NodeState stateOf(Server s) => s.id == 'r' ? NodeState.blocked : NodeState.works;
      expect(compareServers(relay, direct, pingOf, stateOf: stateOf, cdnFirst: true), greaterThan(0),
          reason: 'приговор «не пропускает» важнее режима сети');
    });

    test('restricted: внутри рельс порядок по пингу', () {
      final slow = _relay('slow', ping: 300);
      final fast = _relay('fast', ping: 90);
      expect(compareServers(fast, slow, pingOf, cdnFirst: true), lessThan(0));
    });
  });

  group('ConnectionController.roamRescue — автоподхват рельсы', () {
    test('ручной выбор прямой ноды в restricted, первая попытка → подхват разрешён', () {
      expect(ConnectionController.roamRescue(false, true, 1, _direct('d')), isTrue);
    });
    test('режим «лучший сервер» подхват не использует (там перебор roamContinues)', () {
      expect(ConnectionController.roamRescue(true, true, 1, _direct('d')), isFalse);
    });
    test('кандидат-рельса провалилась → подхватывать нечем', () {
      expect(ConnectionController.roamRescue(false, true, 1, _relay('r')), isFalse);
    });
    test('вторая попытка → стоп (один подхват, не серия)', () {
      expect(ConnectionController.roamRescue(false, true, 2, _direct('d')), isFalse);
    });
    test('обычная сеть → прежнее поведение (причина + подсказка)', () {
      expect(ConnectionController.roamRescue(false, false, 1, _direct('d')), isFalse);
    });
  });

  group('SubNode.isWhitelist — признак CDN-рельсы', () {
    SubNode nodeWithNetwork(String network) => SubNode(
          remark: 'x', tag: 'x', server: 'h', port: 443,
          xray: {'protocol': 'vless', 'streamSettings': {'network': network}},
        );

    test('xhttp/splithttp — рельса', () {
      expect(nodeWithNetwork('xhttp').isWhitelist, isTrue);
      expect(nodeWithNetwork('splithttp').isWhitelist, isTrue);
    });
    test('tcp/ws/grpc — прямая нода', () {
      expect(nodeWithNetwork('tcp').isWhitelist, isFalse);
      expect(nodeWithNetwork('ws').isWhitelist, isFalse);
      expect(nodeWithNetwork('grpc').isWhitelist, isFalse);
    });
    test('без streamSettings — не рельса', () {
      const n = SubNode(remark: 'x', tag: 'x', server: 'h', port: 443, xray: {'protocol': 'vless'});
      expect(n.isWhitelist, isFalse);
    });
  });
}
