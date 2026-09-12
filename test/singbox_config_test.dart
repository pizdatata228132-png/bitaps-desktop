// Юнит-тесты чистого рантайм-критичного модуля singbox_config.dart (генератор sing-box конфига
// из share-link ключа). Плагинов не тянет → гоняется в обычном test-харнессе.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bitaps_vpn/singbox_config.dart';

// Тело подписки в том виде, в каком его отдаёт сервис доставки (/u/<token>): массив ГОТОВЫХ
// xray-конфигов. Первая запись — узел «белого списка» на транспорте xhttp (движок его не умеет),
// дальше — прямые VLESS+Reality. Структура один-в-один с живой выдачей.
const String _subBody = '''
[
 {"remarks":"🛡️ Нидерланды · БС",
  "outbounds":[
   {"tag":"proxy","protocol":"vless",
    "settings":{"vnext":[{"address":"cdn2.bit-core.online","port":443,
      "users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none"}]}]},
    "streamSettings":{"network":"xhttp","security":"tls",
      "tlsSettings":{"serverName":"cdn2.bit-core.online","alpn":["h2","http/1.1"],"fingerprint":"firefox"},
      "xhttpSettings":{"mode":"packet-up","path":"/"}}},
   {"protocol":"freedom","tag":"direct"},
   {"protocol":"blackhole","tag":"block"}]},
 {"remarks":"🇫🇮 Финляндия",
  "outbounds":[
   {"tag":"proxy","protocol":"vless",
    "settings":{"vnext":[{"address":"fi1.bitapsvpn.com","port":8443,
      "users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none","flow":"xtls-rprx-vision"}]}]},
    "streamSettings":{"security":"reality","network":"tcp",
      "realitySettings":{"serverName":"ya.ru","fingerprint":"firefox",
        "publicKey":"mRX3TKTKefW4WrXGIEiKQL1aIWVlfZ5I3Xyf0We4skQ","shortId":"974a7f83c1977d80","spiderX":"/"}}},
   {"protocol":"freedom","tag":"direct"}]},
 {"remarks":"🇳🇱 Нидерланды",
  "outbounds":[
   {"tag":"proxy","protocol":"vless",
    "settings":{"vnext":[{"address":"nl1.bitapsvpn.com","port":8443,
      "users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none","flow":"xtls-rprx-vision"}]}]},
    "streamSettings":{"security":"reality","network":"tcp",
      "realitySettings":{"serverName":"ya.ru","fingerprint":"firefox",
        "publicKey":"rBOGd3DCzFvk9QVW6jQHg9-FM76F05DBDc7FbwOMhmQ","shortId":"149c1b359327a310"}}},
   {"protocol":"freedom","tag":"direct"}]}
]
''';

// Уведомление вместо узлов: сервис так сообщает «истекла» / «лимит устройств».
const String _noticeBody = '''
[
 {"remarks":"❌ Лимит устройств исчерпан",
  "outbounds":[
   {"tag":"proxy","protocol":"vless",
    "settings":{"vnext":[{"address":"127.0.0.1","port":1,
      "users":[{"id":"00000000-0000-0000-0000-000000000000","encryption":"none"}]}]},
    "streamSettings":{"network":"tcp"}}]}
]
''';

void main() {
  group('outboundFromKey — VLESS + Reality', () {
    test('корректный VLESS+Reality с pbk собирается', () {
      const key =
          'vless://3a7c9f1e-0b2d-4e6f-9a1c-7b3e2f8d4c5a@vpn.bitaps.app:443?security=reality&type=tcp&sni=www.microsoft.com&fp=chrome&pbk=PUBLICKEY123&sid=88';
      final out = outboundFromKey(key)!;
      expect(out['type'], 'vless');
      expect(out['tag'], 'proxy');
      expect(out['server'], 'vpn.bitaps.app');
      expect(out['server_port'], 443);
      expect(out['uuid'], '3a7c9f1e-0b2d-4e6f-9a1c-7b3e2f8d4c5a');
      final tls = out['tls'] as Map<String, dynamic>;
      expect(tls['enabled'], true);
      expect(tls['server_name'], 'www.microsoft.com');
      final reality = tls['reality'] as Map<String, dynamic>;
      expect(reality['enabled'], true);
      expect(reality['public_key'], 'PUBLICKEY123');
      expect(reality['short_id'], '88');
      expect((tls['utls'] as Map)['fingerprint'], 'chrome');
      // без transport для type=tcp
      expect(out.containsKey('transport'), false);
    });

    test('НЕГАТИВ: Reality без pbk → FormatException (а не битый конфиг)', () {
      const key =
          'vless://3a7c9f1e-0b2d-4e6f-9a1c-7b3e2f8d4c5a@vpn.bitaps.app:443?security=reality&type=tcp&sni=www.microsoft.com';
      expect(() => outboundFromKey(key), throwsFormatException);
      // и на верхнем уровне тоже фейлит, а не отдаёт полу-конфиг
      expect(() => singboxConfig(key), throwsFormatException);
    });
  });

  group('outboundFromKey — transports', () {
    test('VLESS ws-transport (path percent-decoded + Host header)', () {
      const key =
          'vless://uuid-ws@ws.example.com:443?security=tls&type=ws&path=%2Fvpn%2Fws&host=cdn.example.com';
      final out = outboundFromKey(key)!;
      final t = out['transport'] as Map<String, dynamic>;
      expect(t['type'], 'ws');
      expect(t['path'], '/vpn/ws'); // %2F → '/' через Uri.queryParameters
      expect((t['headers'] as Map)['Host'], 'cdn.example.com');
    });

    test('VLESS grpc-transport (service_name)', () {
      const key =
          'vless://uuid-grpc@grpc.example.com:2053?security=tls&type=grpc&serviceName=GunService';
      final out = outboundFromKey(key)!;
      final t = out['transport'] as Map<String, dynamic>;
      expect(t['type'], 'grpc');
      expect(t['service_name'], 'GunService');
    });
  });

  group('outboundFromKey — прочие протоколы / фолбэки', () {
    test('trojan: percent-decode пароля', () {
      // p%40ss%3Aword → 'p@ss:word'
      const key = 'trojan://p%40ss%3Aword@trojan.example.com:443?security=tls#name';
      final out = outboundFromKey(key)!;
      expect(out['type'], 'trojan');
      expect(out['password'], 'p@ss:word');
      expect((out['tls'] as Map)['enabled'], true);
    });

    test('vmess: base64 без паддинга декодируется (base64 fallback)', () {
      const vmessJson =
          '{"v":"2","ps":"n","add":"vm.example.com","port":"8443","id":"vmess-uuid","aid":"0","net":"ws","host":"h.example.com","path":"/p","tls":"tls"}';
      final b64 = base64.encode(utf8.encode(vmessJson)).replaceAll('=', ''); // без '='
      final out = outboundFromKey('vmess://$b64')!;
      expect(out['type'], 'vmess');
      expect(out['server'], 'vm.example.com');
      expect(out['server_port'], 8443);
      expect(out['uuid'], 'vmess-uuid');
      expect((out['tls'] as Map)['enabled'], true);
      expect((out['transport'] as Map)['type'], 'ws');
      expect((out['transport'] as Map)['path'], '/p');
    });

    test('shadowsocks форма A: base64(userinfo)@host:port', () {
      final userinfo = base64.encode(utf8.encode('aes-256-gcm:secretpass'));
      final out = outboundFromKey('ss://$userinfo@ss.example.com:8388#tag')!;
      expect(out['type'], 'shadowsocks');
      expect(out['server'], 'ss.example.com');
      expect(out['server_port'], 8388);
      expect(out['method'], 'aes-256-gcm');
      expect(out['password'], 'secretpass');
    });

    test('неизвестная схема → null', () {
      expect(outboundFromKey('ftp://nope.example.com'), isNull);
    });
  });

  group('singboxConfig — полный конфиг', () {
    const key =
        'vless://uuid-x@vpn.bitaps.app:443?security=reality&type=tcp&pbk=PUBKEY&sid=01';

    test('содержит tun-inbound, outbound proxy+direct и route', () {
      final cfg = singboxConfig(key);
      final inbounds = cfg['inbounds'] as List;
      expect((inbounds.first as Map)['type'], 'tun');
      final outbounds = cfg['outbounds'] as List;
      expect((outbounds[0] as Map)['tag'], 'proxy');
      expect((outbounds[1] as Map)['tag'], 'direct');
      expect(cfg.containsKey('dns'), true);
      expect(cfg.containsKey('route'), true);
    });

    test('singboxConfigJson отдаёт валидный JSON', () {
      final jsonStr = singboxConfigJson(key);
      final decoded = json.decode(jsonStr);
      expect(decoded, isA<Map>());
      expect(jsonStr.contains('"tag": "proxy"'), true);
    });

    test('невалидный ключ → FormatException', () {
      expect(() => singboxConfig('not-a-key'), throwsFormatException);
    });
  });

  group('подписка — распознавание ссылки', () {
    test('ссылка сервиса доставки принимается', () {
      expect(isSubscriptionUrl('https://origin.bit-core.online/u/u4db1f0bb3e5eda5f5d2ed5'), true);
      expect(isSubscriptionUrl('  https://origin.bit-core.online/u/abcdefgh  '), true);
    });

    test('НЕГАТИВ: чужой домен, http, кривой путь и токен отвергаются', () {
      // чужой хост — иначе произвольная ссылка стала бы «ключом» и подменила конфиг
      expect(isSubscriptionUrl('https://evil.example.com/u/abcdefghij'), false);
      // домен-обманка: bit-core.online.evil.com не является поддоменом bit-core.online
      expect(isSubscriptionUrl('https://bit-core.online.evil.com/u/abcdefghij'), false);
      expect(isSubscriptionUrl('http://origin.bit-core.online/u/abcdefghij'), false);
      expect(isSubscriptionUrl('https://origin.bit-core.online/sub/abcdefghij'), false);
      expect(isSubscriptionUrl('https://origin.bit-core.online/u/short'), false);
      expect(isSubscriptionUrl('https://origin.bit-core.online/u/имя-с-символами'), false);
      expect(isSubscriptionUrl('vless://uuid@host:443'), false);
    });
  });

  group('подписка — разбор тела', () {
    test('xhttp-узел достаётся xray, sing-box получает только свои', () {
      final r = parseSubscription(_subBody);
      // 3 записи: одна xhttp («БС») + две Reality. Для xray годятся все три,
      // для sing-box — только две: транспорта xhttp у него нет.
      expect(r.nodes.length, 3);
      expect(r.singboxNodes.length, 2);
      expect(r.nodes.first.singboxReady, false); // «БС» на xhttp
      expect(r.nodes.first.xray['streamSettings']['network'], 'xhttp');
      expect(r.skipped, 0);
      expect(r.notice, isNull);
      expect(r.hasNodes, true);
      expect(r.singboxNodes.map((n) => n.tag).toList(), ['🇫🇮 Финляндия', '🇳🇱 Нидерланды']);

      final fi = r.singboxNodes.first.singbox!;
      expect(fi['type'], 'vless');
      expect(fi['server'], 'fi1.bitapsvpn.com');
      expect(fi['server_port'], 8443);
      expect(fi['uuid'], '11111111-2222-3333-4444-555555555555');
      expect(fi['flow'], 'xtls-rprx-vision');
      expect(fi['packet_encoding'], 'xudp');
      final tls = fi['tls'] as Map<String, dynamic>;
      expect(tls['server_name'], 'ya.ru');
      expect((tls['utls'] as Map)['fingerprint'], 'firefox');
      final reality = tls['reality'] as Map<String, dynamic>;
      expect(reality['enabled'], true);
      expect(reality['public_key'], 'mRX3TKTKefW4WrXGIEiKQL1aIWVlfZ5I3Xyf0We4skQ');
      expect(reality['short_id'], '974a7f83c1977d80');
      // tcp → без блока transport
      expect(fi.containsKey('transport'), false);
    });

    test('уведомление сервиса вместо узлов — это НЕ узел', () {
      final r = parseSubscription(_noticeBody);
      expect(r.hasNodes, false);
      expect(r.notice, 'Лимит устройств исчерпан');
    });

    test('Reality без публичного ключа не попадает в sing-box конфиг', () {
      // адрес — на доверенном домене, чтобы узел прошёл гейт хостов и тест проверял
      // именно отсеивание по битому Reality, а не по адресу
      const body = '''
[{"remarks":"битый","outbounds":[{"tag":"proxy","protocol":"vless",
  "settings":{"vnext":[{"address":"broken.bitapsvpn.com","port":443,"users":[{"id":"u"}]}]},
  "streamSettings":{"security":"reality","network":"tcp","realitySettings":{"serverName":"ya.ru"}}}]}]''';
      final r = parseSubscription(body);
      // узел разобран (xray попробует), но для sing-box он невалиден → в его конфиг не попадёт
      expect(r.singboxNodes, isEmpty);
      expect(() => singboxConfigFromNodes(r.nodes), throwsFormatException);
    });

    test('одинаковые remarks дают РАЗНЫЕ теги (иначе конфиг невалиден)', () {
      final body = _subBody.replaceAll('🇳🇱 Нидерланды', '🇫🇮 Финляндия');
      final r = parseSubscription(body);
      expect(r.nodes.length, 3);
      expect(r.nodes.map((n) => n.tag).toSet().length, 3);
    });

    test('не-массив в теле → FormatException', () {
      expect(() => parseSubscription('{"remarks":"x"}'), throwsFormatException);
    });

    test('узел с ЧУЖИМ адресом отбрасывается (MITM-гейт) и честно считается в skipped', () {
      // Поддельная запись с говорящим ремарком и адресом атакующего: без гейта через неё
      // пошёл бы ВЕСЬ трафик (десктопный роутинг гонит всё через node-*).
      const body = '''
[
 {"remarks":"🇫🇮 Финляндия","outbounds":[
  {"tag":"proxy","protocol":"vless",
   "settings":{"vnext":[{"address":"evil.example.com","port":443,
     "users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none"}]}]},
   "streamSettings":{"network":"tcp"}}]},
 {"remarks":"🇳🇱 Нидерланды","outbounds":[
  {"tag":"proxy","protocol":"vless",
   "settings":{"vnext":[{"address":"nl1.bitapsvpn.com","port":443,
     "users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none"}]}]},
   "streamSettings":{"network":"tcp"}}]}
]
''';
      final r = parseSubscription(body);
      expect(r.nodes.length, 1, reason: 'чужой узел не должен попасть в конфиг');
      expect(r.nodes.single.server, 'nl1.bitapsvpn.com');
      expect(r.skipped, 1, reason: 'отброшенный узел должен быть виден в счётчике');
      // домен-обманка гейт не пропускает
      expect(isTrustedBitapsHost('bitapsvpn.com.evil.example.com'), isFalse);
      // сырые IP: доменный гейт не пропускает (URL/ключи), а узловый пропускает ТОЛЬКО
      // точные IP боевого флота — произвольный IP атакующего по-прежнему отброшен
      expect(isTrustedBitapsHost('153.80.241.50'), isFalse);
      expect(isTrustedNodeHost('153.80.241.50'), isTrue, reason: 'IP боевой ноды FI (4VPS)');
      expect(isTrustedNodeHost('212.237.219.223'), isFalse, reason: 'старое FI (vdsina) выведено из флота');
      expect(isTrustedNodeHost('203.0.113.66'), isFalse, reason: 'чужой IP отброшен');
    });

    test('ADV-3: multi-member vnext с чужим вторым членом отбрасывается целиком', () {
      // Гейт проверял только ПЕРВЫЙ член vnext/servers, а multi-member запись движок не
      // поднимает вообще: доверенный первый + evil второй проходили проверку доверия,
      // и гейт с движком расходились (аудит, defense-in-depth). Теперь член обязан быть
      // ровно один — иначе запись отбрасывается, как поступил бы и движок.
      const body = '''
[
 {"remarks":"🇫🇮 Финляндия","outbounds":[
  {"tag":"proxy","protocol":"vless",
   "settings":{"vnext":[
     {"address":"fi1.bitapsvpn.com","port":443,
      "users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none"}]},
     {"address":"evil.example.com","port":443,
      "users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none"}]}]},
   "streamSettings":{"network":"tcp"}}]}
]
''';
      final r = parseSubscription(body);
      expect(r.nodes, isEmpty, reason: 'multi-member запись гейт пропускать не должен');
      expect(r.skipped, 1, reason: 'отброшенная запись должна быть видна в счётчике');
    });

    test('узел с IP боевой ноды (как в живой выдаче) проходит гейт', () {
      // subserver.py отдаёт прямые ноды сырыми IP — гейт обязан их принимать.
      const body = '''
[
 {"remarks":"🇫🇮 Финляндия","outbounds":[
  {"tag":"proxy","protocol":"vless",
   "settings":{"vnext":[{"address":"153.80.241.50","port":8443,
     "users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none"}]}]},
   "streamSettings":{"network":"tcp"}}]}
]
''';
      final r = parseSubscription(body);
      expect(r.nodes.length, 1);
      expect(r.nodes.single.server, '153.80.241.50');
      expect(r.skipped, 0);
    });

    test('кап на число узлов: лишние обрезаются и считаются в skipped', () {
      String entry(int i) => '{"remarks":"n$i","outbounds":[{"tag":"proxy","protocol":"vless",'
          '"settings":{"vnext":[{"address":"n$i.bitapsvpn.com","port":443,'
          '"users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none"}]}]},'
          '"streamSettings":{"network":"tcp"}}]}';
      final body = '[${[for (var i = 0; i < kSubMaxNodes + 25; i++) entry(i)].join(',')}]';
      final r = parseSubscription(body);
      expect(r.nodes.length, kSubMaxNodes, reason: '10^5 узлов = часы проб, список капаем');
      expect(r.skipped, 25);
    });
  });

  group('подписка — сборка конфига', () {
    test('selector proxy + urltest auto + узлы + direct', () {
      final r = parseSubscription(_subBody);
      final cfg = singboxConfigFromNodes(r.nodes);
      final outs = (cfg['outbounds'] as List).cast<Map<String, dynamic>>();
      expect(outs.first['type'], 'selector');
      expect(outs.first['tag'], 'proxy'); // на этот тег смотрят route.final и DNS-детуры
      expect(outs.first['outbounds'], ['auto', '🇫🇮 Финляндия', '🇳🇱 Нидерланды']);
      expect(outs[1]['type'], 'urltest');
      expect(outs[1]['tag'], 'auto');
      expect(outs[1]['outbounds'], ['🇫🇮 Финляндия', '🇳🇱 Нидерланды']);
      expect(outs.last['type'], 'direct');
      // все теги уникальны — иначе движок отвергнет конфиг
      final tags = outs.map((o) => o['tag']).toList();
      expect(tags.toSet().length, tags.length);
      expect((cfg['route'] as Map)['final'], 'proxy');
      expect(((cfg['inbounds'] as List).first as Map)['type'], 'tun');
    });

    test('пустой список узлов → FormatException (а не пустой конфиг)', () {
      expect(() => singboxConfigFromNodes(const []), throwsFormatException);
    });

    test('JSON конфига подписки валиден и содержит оба узла', () {
      final r = parseSubscription(_subBody);
      final decoded = json.decode(singboxConfigJsonFromNodes(r.nodes));
      expect(decoded, isA<Map>());
      expect(json.encode(decoded).contains('fi1.bitapsvpn.com'), true);
      expect(json.encode(decoded).contains('nl1.bitapsvpn.com'), true);
      // xhttp-узел в конфиг не попал
      expect(json.encode(decoded).contains('cdn2.bit-core.online'), false);
    });
  });

  group('подписка — загрузка по сети', () {
    test('200 + тело → узлы, заголовки разобраны', () async {
      String? sentHwid;
      final client = MockClient((req) async {
        sentHwid = req.headers['x-hwid'];
        return http.Response(_subBody, 200, headers: {
          'content-type': 'application/json; charset=utf-8',
          'subscription-userinfo': 'expire=1800000000',
        });
      });
      final res = await fetchSubscription('https://origin.bit-core.online/u/abcdefghij',
          hwid: 'abcdef0123456789', deviceOs: 'linux', client: client);
      expect(res.ok, true);
      expect(res.nodes.length, 3);
      expect(res.skipped, 0);
      expect(sentHwid, 'abcdef0123456789'); // без него сервис не посчитает устройство
      expect(res.expiresAt?.millisecondsSinceEpoch, 1800000000 * 1000);
    });

    test('уведомление в заголовке base64 доходит до пользователя', () async {
      const msg = 'Подписка истекла. Продлите её в приложении или боте.';
      // charset обязателен: без него http.Response кодирует тело latin1 и кириллица падает
      // (живой сервис отдаёт ровно 'application/json; charset=utf-8').
      final client = MockClient((_) async => http.Response(_noticeBody, 200, headers: {
            'content-type': 'application/json; charset=utf-8',
            'sub-info-text': 'base64:${base64.encode(utf8.encode(msg))}',
            'sub-info-color': 'red',
          }));
      final res = await fetchSubscription('https://origin.bit-core.online/u/abcdefghij',
          hwid: 'abcdef0123456789', client: client);
      expect(res.ok, false);
      expect(res.notice, msg);
      expect(res.error, isNull); // это не ошибка сети, а осмысленный ответ сервиса
    });

    test('не-200 и мусор в теле → ошибка, но НЕ исключение', () async {
      final bad = MockClient((_) async => http.Response('nope', 503));
      final r1 = await fetchSubscription('https://origin.bit-core.online/u/abcdefghij',
          hwid: 'abcdef0123456789', client: bad);
      expect(r1.ok, false);
      expect(r1.error, contains('503'));

      final garbage = MockClient((_) async => http.Response('<html>not json</html>', 200));
      final r2 = await fetchSubscription('https://origin.bit-core.online/u/abcdefghij',
          hwid: 'abcdef0123456789', client: garbage);
      expect(r2.ok, false);
      expect(r2.error, isNotNull);
    });

    test('зависший сервер → таймаут, а не вечное «Подключение…»', () async {
      final slow = MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return http.Response(_subBody, 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });
      final res = await fetchSubscription('https://origin.bit-core.online/u/abcdefghij',
          hwid: 'abcdef0123456789', client: slow, timeout: const Duration(milliseconds: 50));
      expect(res.ok, false);
      expect(res.error, isNotNull);
    });

    test('тело больше лимита отвергается ДО разбора — защита от OOM', () async {
      // Валидный по форме JSON, но за капом по размеру: режем на чтении, не буферизуя всё.
      final big = '${' ' * (kSubMaxBytes + 1)}[]';
      final client = MockClient((_) async => http.Response(big, 200,
          headers: {'content-type': 'application/json; charset=utf-8'}));
      final res = await fetchSubscription('https://origin.bit-core.online/u/abcdefghij',
          hwid: 'abcdef0123456789', client: client);
      expect(res.ok, false);
      expect(res.error, contains('слишком большая'));
      expect(res.nodes, isEmpty);
    });
  });
}
