// Юнит-тесты импорта СТОРОННИХ подписок (08.10): список share-link'ов base64/plain вместо
// xray-JSON. Раньше такая выдача отвергалась «подписка повреждена» — сторонний сервис
// добавить было невозможно. Модуль чистый (без плагинов) — гоняется в обычном test-харнессе.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:bitaps_vpn/singbox_config.dart';
import 'package:bitaps_vpn/xray_config.dart';

const _vless1 =
    'vless://11111111-2222-3333-4444-555555555555@one.example.com:443?security=tls&type=tcp&sni=one.example.com&fp=chrome#%D0%9E%D0%B4%D0%B8%D0%BD';
const _vless2 =
    'vless://11111111-2222-3333-4444-555555555555@two.example.com:8443?security=reality&type=tcp&flow=xtls-rprx-vision&sni=ya.ru&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=ab#Two';
const _ss = 'ss://MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206cGFzc3dvcmQxMjM0NTY=@three.example.com:14443#Three';

void main() {
  test('plain-список ссылок: узлы с именами из #фрагмента', () {
    final r = parseLinksSubscription('$_vless1\n$_vless2\n$_ss\n');
    expect(r.nodes, hasLength(3));
    expect(r.nodes[0].remark, 'Один'); // percent-decode фрагмента
    expect(r.nodes[1].remark, 'Two');
    expect(r.nodes[0].server, 'one.example.com');
    expect(r.nodes[1].port, 8443);
  });

  test('base64-блоб разворачивается и разбирается', () {
    final blob = base64.encode(utf8.encode('$_vless1\n$_ss'));
    final r = parseLinksSubscription(blob);
    expect(r.nodes, hasLength(2));
    expect(r.nodes[1].server, 'three.example.com');
  });

  test('мусорные строки считаются в skipped, разбор не роняют', () {
    final r = parseLinksSubscription('<html>403 Forbidden</html>\n$_vless2\nтекст');
    expect(r.nodes, hasLength(1));
    expect(r.skipped, 2);
  });

  test('битый ключ знакомой схемы → skipped, а не узел', () {
    final r = parseLinksSubscription('vless://\n$_vless1');
    expect(r.nodes, hasLength(1));
    expect(r.skipped, 1);
  });

  test('parseSubscription(allowForeign): не-JSON уходит в ссылки, без allowForeign — FormatException', () {
    expect(() => parseSubscription('not json at all'), throwsFormatException);
    final r = parseSubscription('$_vless1', allowForeign: true);
    expect(r.nodes, hasLength(1));
  });

  test('parseSubscription(allowForeign): JSON-подписка с чужими хостами не режется гейтом', () {
    final body = jsonEncode([
      {
        'remarks': 'Чужой узел',
        'outbounds': [
          {
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'foreign.example.net',
                  'port': 443,
                  'users': [
                    {'id': '11111111-2222-3333-4444-555555555555', 'encryption': 'none'}
                  ]
                }
              ]
            },
            'streamSettings': {'network': 'tcp', 'security': 'none'}
          }
        ]
      }
    ]);
    final strict = parseSubscription(body);
    expect(strict.nodes, isEmpty); // гейт bitaps-хостов отрезал
    expect(strict.skipped, 1);
    final loose = parseSubscription(body, allowForeign: true);
    expect(loose.nodes, hasLength(1));
    expect(loose.nodes.single.server, 'foreign.example.net');
  });
}
