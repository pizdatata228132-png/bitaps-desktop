// Персистентный кэш подписки (fetchSubscriptionCached + subCacheEncode/Decode) — опора
// против сетей режима «белых списков», где выдача origin.bit-core.online заблокирована.
//
// Зачем именно этот тест. Кэш — единственное, что даёт список узлов и подключение, когда
// выдача мертва. Ошибки здесь симметрично плохи: «не записал/не прочитал» — нет подключения
// в restricted-сети; «подменил ответ сервиса кэшем» — человек с истёкшей подпиской или
// чужим токеном подключился бы к старым узлам мимо ответа сервиса. Фиксируем: запись после
// успеха, молчаливое чтение при сбое сети, TTL 7 дней, привязку к url (токену) и запрет
// подмены notice-ответа («подписка истекла»/«лимит устройств») кэшем.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:bitaps_vpn/singbox_config.dart';

// Хранилище-фейк вместо SharedPreferences: контракт SubCacheStore (singbox_config.dart —
// чистый Dart, CI гоняет его через `dart run`).
class _FakeStore implements SubCacheStore {
  final Map<String, String> m;
  _FakeStore([Map<String, String>? initial]) : m = initial ?? {};
  @override
  Future<String?> read() async => m[kSubCachePrefsKey];
  @override
  Future<void> write(String v) async { m[kSubCachePrefsKey] = v; }
}

const _url = 'https://origin.bit-core.online/u/abcdefghij';

// Тело выдачи с одним живым узлом (CDN-рельса на доверенном домене — гейт пропускает).
const String _subBody = '''
[
 {"remarks":"🛡️ Нидерланды · LTE",
  "outbounds":[
   {"tag":"proxy","protocol":"vless",
    "settings":{"vnext":[{"address":"cdn2.bit-core.online","port":443,
      "users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none"}]}]},
    "streamSettings":{"network":"xhttp","security":"tls",
      "tlsSettings":{"serverName":"cdn2.bit-core.online"}}},
   {"protocol":"freedom","tag":"direct"},
   {"protocol":"blackhole","tag":"block"}]}
]
''';

// Уведомление вместо узлов: сервис так сообщает «истекла» / «лимит устройств».
const String _noticeBody = '''
[
 {"remarks":"❌ Подписка истекла",
  "outbounds":[
   {"tag":"proxy","protocol":"vless",
    "settings":{"vnext":[{"address":"127.0.0.1","port":1,
      "users":[{"id":"00000000-0000-0000-0000-000000000000","encryption":"none"}]}]},
    "streamSettings":{"network":"tcp"}}]}
]
''';

// charset utf-8 обязателен: без него http.Response кодирует тело latin1 и кириллица падает
// (живой сервис отдаёт ровно 'application/json; charset=utf-8') — см. singbox_config_test.
http.Client _ok([String body = _subBody]) => MockClient(
    (_) async => http.Response(body, 200, headers: {'content-type': 'application/json; charset=utf-8'}));
http.Client _fail() => MockClient((_) async => http.Response('boom', 500));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('subCacheEncode/Decode — чистая механика записи', () {
    test('round-trip: тело и дата возвращаются', () {
      final at = DateTime.now();
      final raw = subCacheEncode(_url, _subBody, at);
      final decoded = subCacheDecode(raw, _url);
      expect(decoded, isNotNull);
      expect(decoded!.body, _subBody);
      expect(decoded.at.toIso8601String(), at.toIso8601String());
    });

    test('чужой url (другой токен) кэш не получает', () {
      final raw = subCacheEncode(_url, _subBody, DateTime.now());
      expect(subCacheDecode(raw, 'https://origin.bit-core.online/u/zzzzzzzzzz'), isNull,
          reason: 'кэш одного аккаунта не должен подставляться другому');
    });

    test('протухший кэш (8 дней при TTL 7) игнорируется', () {
      final at = DateTime.now().subtract(const Duration(days: 8));
      final raw = subCacheEncode(_url, _subBody, at);
      expect(subCacheDecode(raw, _url), isNull, reason: 'протухший — игнор + честная ошибка');
    });

    test('битая/пустая запись → null, а не падение', () {
      expect(subCacheDecode('не json', _url), isNull);
      expect(subCacheDecode('', _url), isNull);
      expect(subCacheDecode(null, _url), isNull);
      expect(subCacheDecode('{"url":"$_url"}', _url), isNull, reason: 'нет тела/даты');
    });
  });

  group('fetchSubscriptionCached — сеть + кэш', () {
    test('успешная выдача пишет кэш и не помечена cachedAt', () async {
      final p = _FakeStore();
      final res = await fetchSubscriptionCached(_url, hwid: 'hwidtest0001', client: _ok(), store: p);
      expect(res.ok, isTrue);
      expect(res.cachedAt, isNull, reason: 'свежая выдача — пометки кэша быть не должно');
      expect(p.m[kSubCachePrefsKey], isNotNull, reason: 'успех обязан обновить кэш');
    });

    test('сбой сети → молча список из кэша с датой cachedAt', () async {
      final at = DateTime.now().subtract(const Duration(hours: 3));
      final p = _FakeStore({kSubCachePrefsKey: subCacheEncode(_url, _subBody, at)});
      final res = await fetchSubscriptionCached(_url, hwid: 'hwidtest0001', client: _fail(), store: p);
      expect(res.ok, isTrue, reason: 'кэш обязан дать рабочий список при мёртвой выдаче');
      expect(res.nodes.length, 1);
      expect(res.cachedAt, isNotNull, reason: 'UI должен показать «список из кэша от <дата>»');
      expect(res.cachedAt!.toIso8601String(), at.toIso8601String());
      expect(res.error, isNull);
    });

    test('сбой сети и протухший кэш → честная ошибка, как раньше', () async {
      final at = DateTime.now().subtract(const Duration(days: 9));
      final p = _FakeStore({kSubCachePrefsKey: subCacheEncode(_url, _subBody, at)});
      final res = await fetchSubscriptionCached(_url, hwid: 'hwidtest0001', client: _fail(), store: p);
      expect(res.ok, isFalse);
      expect(res.error, isNotNull, reason: 'протухший кэш игнорируем — ошибка как без кэша');
      expect(res.cachedAt, isNull);
    });

    test('сбой сети без кэша → ошибка без подмены', () async {
      final p = _FakeStore();
      final res = await fetchSubscriptionCached(_url, hwid: 'hwidtest0001', client: _fail(), store: p);
      expect(res.ok, isFalse);
      expect(res.error, isNotNull);
      expect(res.nodes, isEmpty);
    });

    test('notice-ответ сервиса кэшем НЕ подменяется', () async {
      final p = _FakeStore({kSubCachePrefsKey: subCacheEncode(_url, _subBody, DateTime.now())});
      final res =
          await fetchSubscriptionCached(_url, hwid: 'hwidtest0001', client: _ok(_noticeBody), store: p);
      expect(res.ok, isFalse, reason: 'узлов нет — ok быть не должно');
      expect(res.error, isNull);
      expect(res.notice, contains('Подписка истекла'),
          reason: 'истёкшая подписка обязана показать notice, а не подключиться к кэшу');
      expect(res.nodes, isEmpty);
    });
  });
}
