// Сборка конфигурации для движка XRAY из узлов подписки.
//
// Зачем отдельно от singbox_config.dart: узлы «белого списка» (БС) ходят транспортом **xhttp**
// через CDN, а такого транспорта в sing-box нет — он есть только в xray. Записи подписки сами
// по себе УЖЕ являются xray-конфигами, поэтому здесь ничего не «переводится»: мы берём сырой
// outbound узла как есть и собираем из всех узлов ОДИН конфиг с балансировщиком. Значит движку
// xray доступны все узлы, включая БС.
//
// Формат повторяет боевой генератор подписок на хабе (gen_sub.py, порт проверенной схемы Orvia):
// burstObservatory замеряет узлы по собственному 204-эндпоинту, балансировщик выбирает лучший.

import 'dart:convert';

import 'singbox_config.dart' show SubNode, SubParseResult, outboundFromKey, kSupportedKeySchemes, kSubMaxNodes;

/// Локальный вход, который поднимает движок: в него ходит системный прокси/tun2socks.
const int kXraySocksPort = 10808;

/// Тот же вход на Android — но на СВОЁМ порту.
///
/// 10808 — порт по умолчанию у v2rayNG, Happ и почти всех клиентов на xray. Пока на телефоне
/// стоит любой из них, порт занят, наш движок не может открыть локальный вход и туннель
/// поднимается пустым: система показывает VPN, а трафика нет. В обратную сторону так же —
/// Happ жаловался «порт уже занят», когда первыми успевали мы. Свой порт снимает конфликт:
/// два клиента спокойно живут на одном телефоне (одновременно активен всё равно только один —
/// это ограничение самого Android, а не наше).
const int kXrayAndroidSocksPort = 10836;
/// Локальный вход ВРЕМЕННОГО экземпляра движка на время проверки узла. Отдельный от боевого:
/// проверка идёт при живом подключении, и занятый порт сорвал бы либо её, либо сам туннель.
const int kXrayProbeSocksPort = 10837;

/// Собственный 204-эндпоинт для замеров балансировщика. Публичные (gstatic) в РФ недоступны,
/// а старый cdn.bit-core.online больше не отвечает — используем ориджин выдачи, он живой.
const String kXrayObservatoryUrl = 'https://origin.bit-core.online/gen204';

/// DNS как в записях подписки: DoH-резолверы (запросы зашифрованы) + системный.
/// Plain `77.88.8.8` убран (аудит A14): весь DNS уходил провайдеру открытым текстом — полная
/// история резолвов, включая блокируемые домены, у которых дальше трафик идёт туннелем.
const List<dynamic> _kDns = [
  {'address': 'https://77.88.8.8/dns-query', 'tag': 'doh-yandex'},
  {'address': 'https://8.8.8.8/dns-query', 'tag': 'doh-google'},
  'localhost',
];

/// Один конфиг xray со ВСЕМИ узлами подписки и авто-выбором лучшего.
///
/// [nodes] — узлы из подписки (годятся любые, включая xhttp).
/// [only] — тег единственного узла, если пользователь выбрал сервер вручную (тогда без балансировщика).
/// [socksPort] — порт локального socks-входа.
Map<String, dynamic> xrayConfigFromNodes(
  List<SubNode> nodes, {
  String? only,
  int socksPort = kXraySocksPort,
  int? httpPort,
  int? metricsPort,
}) {
  if (nodes.isEmpty) {
    throw const FormatException('в подписке нет узлов для подключения');
  }
  // ВСЕ узлы остаются в конфиге, даже когда пользователь выбрал один: выбор — это правило
  // маршрутизации (outboundTag), а не усечение списка, поэтому запасной путь не теряется.
  final outbounds = <Map<String, dynamic>>[];
  final tags = <String>[];
  String? whitelistTag; // «БС» — узел, который переживает блокировку прямых нод
  String? pinnedTag;
  for (var i = 0; i < nodes.length; i++) {
    // копия сырого outbound'а с нашим тегом: сам узел не трогаем, чтобы не потерять
    // ни xhttp-настройки, ни reality-параметры
    final raw = json.decode(json.encode(nodes[i].xray)) as Map<String, dynamic>;
    final tag = 'node-$i';
    raw['tag'] = tag;
    tags.add(tag);
    if (nodes[i].tag == only) pinnedTag = tag;
    final network = ((raw['streamSettings'] as Map?)?['network'] ?? '').toString();
    if (whitelistTag == null && (network == 'xhttp' || network == 'splithttp')) whitelistTag = tag;
    outbounds.add(raw);
  }
  if (only != null && pinnedTag == null) {
    throw const FormatException('выбранный сервер отсутствует в подписке');
  }
  final balanced = pinnedTag == null && tags.length > 1;
  outbounds.add({
    'protocol': 'freedom',
    'tag': 'direct',
    'settings': {'domainStrategy': 'UseIPv4'},
  });
  outbounds.add({'protocol': 'blackhole', 'tag': 'block'});

  final cfg = <String, dynamic>{
    'log': {'loglevel': 'warning'},
    'dns': {'queryStrategy': 'UseIPv4', 'disableCache': false, 'servers': _kDns},
    'inbounds': [
      if (httpPort != null)
        // HTTP-вход нужен системному прокси: часть приложений (и сам Windows) ходит только
        // через http/https-прокси и socks-настройку игнорирует.
        {
          'listen': '127.0.0.1',
          'port': httpPort,
          'protocol': 'http',
          'tag': 'http',
        },
      {
        'listen': '127.0.0.1',
        'port': socksPort,
        'protocol': 'socks',
        'settings': {'udp': true, 'auth': 'noauth'},
        'sniffing': {
          'enabled': true,
          'destOverride': ['http', 'tls', 'quic'],
          'routeOnly': true,
        },
        'tag': 'socks',
      },
    ],
    'outbounds': outbounds,
    if (metricsPort != null) ...{
      // Счётчики трафика и состояние узлов движок отдаёт сам по HTTP на localhost
      // (/debug/vars) — приложение показывает НАСТОЯЩИЕ цифры, не выдуманные.
      'stats': <String, dynamic>{},
      'policy': {
        'system': {'statsOutboundUplink': true, 'statsOutboundDownlink': true},
      },
      'metrics': {'tag': 'metrics_out', 'listen': '127.0.0.1:$metricsPort'},
    },
    'routing': {
      'domainMatcher': 'hybrid',
      'domainStrategy': 'IPIfNonMatch',
      if (balanced)
        'balancers': [
          {
            'tag': 'gen-bal',
            'selector': ['node-'],
            // Когда обсерватория считает все узлы мёртвыми (ровно сценарий блокировки прямых
            // нод), балансировщику нужен запасной — берём узел «белого списка»: он ходит через
            // CDN и переживает то, что убивает прямые ноды. Нет БС — падаем на первый узел.
            'fallbackTag': whitelistTag ?? tags.first,
            'strategy': {'type': 'leastPing'},
          },
        ],
      'rules': _rules(balanced, pinnedTag),
    },
  };
  if (balanced) {
    // Замер узлов: без него балансировщик не знает, кто быстрее. Классическая обсерватория
    // отдаёт задержку в миллисекундах прямо в /debug/vars — её же показываем как пинг узла.
    // Интервал намеренно редкий: каждый замер — это реальное соединение к каждой ноде.
    cfg['observatory'] = {
      'subjectSelector': ['node-'],
      'probeUrl': kXrayObservatoryUrl,
      'probeInterval': '5m',
      'enableConcurrency': true,
    };
  }
  return cfg;
}

/// iOS-вариант конфига: те же узлы/балансировщик/правила/DNS, но входом служит tun-интерфейс
/// NetworkExtension (fd движку передаётся через env {"xray.tun.fd"} на старте — см.
/// ios/PacketTunnel/PacketTunnelProvider.swift). socks/http входы на iOS не нужны — трафик
/// приходит из utun, а не из системного прокси.
Map<String, dynamic> xrayConfigForIos(
  List<SubNode> nodes, {
  String? only,
}) {
  final base = xrayConfigFromNodes(nodes, only: only, socksPort: kXraySocksPort);
  base['inbounds'] = [
    {
      'protocol': 'tun',
      'tag': 'tun',
      'settings': {
        'name': 'bitaps-tun',
        'MTU': 1500,
        'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
        // Маршруты ставит NetworkExtension (includedRoutes), а не xray — иначе конфликт
        // таблиц маршрутизации с системным провайдером.
        'autoRoute': false,
        'strictRoute': false,
        'stack': 'system',
      },
      'sniffing': {
        'enabled': true,
        'destOverride': ['http', 'tls', 'quic'],
        'routeOnly': true,
      },
    },
  ];
  return base;
}

/// То же, JSON-строкой (для MethodChannel).
String xrayConfigJsonForIos(List<SubNode> nodes, {String? only}) =>
    jsonEncode(xrayConfigForIos(nodes, only: only));

/// Конфиг БЫСТРОГО замера всего флота ОДНИМ процессом (десктоп, кнопка «Проверить серверы»).
///
/// Раньше на КАЖДЫЙ узел поднимался свой временный процесс xray — флот из ~13 узлов мерился
/// 10–12 с и грузил машину шестью процессами разом. Здесь один процесс: все узлы — outbounds,
/// observatory с интервалом в секунду прозванивает их параллельно (enableConcurrency) и пишет
/// alive/rtt каждого в /debug/vars, который мы читаем спустя ~3–4 с (см. probeFleet в
/// engine.dart). Балансировщик и правила наследуются от боевого конфига — трафика через
/// процесс всё равно нет, важны только замеры обсерватории. Чистая функция — покрыта
/// fleet_probe_test.
Map<String, dynamic> xrayFleetProbeConfig(
  List<SubNode> nodes, {
  required int socksPort,
  required int metricsPort,
  String probeInterval = '1s',
}) {
  final cfg = xrayConfigFromNodes(nodes, socksPort: socksPort, metricsPort: metricsPort);
  // Observatory ставим безусловно (база добавляет её только при балансировке): замер нужен
  // и для флота из одного узла. Интервал 1с вместо боевых 5m — проба разовая и временная.
  cfg['observatory'] = {
    'subjectSelector': ['node-'],
    'probeUrl': kXrayObservatoryUrl,
    'probeInterval': probeInterval,
    'enableConcurrency': true,
  };
  return cfg;
}

/// Тот же конфиг строкой — уходит временному процессу движка.
String xrayFleetProbeConfigJson(
  List<SubNode> nodes, {
  required int socksPort,
  required int metricsPort,
  String probeInterval = '1s',
}) =>
    const JsonEncoder.withIndent('  ').convert(
        xrayFleetProbeConfig(nodes, socksPort: socksPort, metricsPort: metricsPort, probeInterval: probeInterval));

/// Конфиг ОДНОГО узла — запись подписки после САНИТИЗАЦИИ. Используется на Android.
///
/// Почему не общий конфиг со всеми узлами. На Android движок живёт внутри системного
/// VpnService (плагин), и там наша сборка «15 исходов + балансировщик + обсерватория +
/// метрики» вела себя так: туннель поднимался, а трафик не шёл. Тот же телефон с тем же
/// сервером в стороннем клиенте работал — потому что клиент берёт ИМЕННО эту запись подписки,
/// без наших надстроек. Вместо того чтобы гадать, какая из надстроек мешает внутри чужого
/// VpnService, отдаём проверенную запись — но НЕ verbatim (аудит, HIGH).
///
/// Запись приходит по сети и для движка является чужим контентом: вредоносная запись могла
/// поднять на устройстве публичный SOCKS (inbound с listen 0.0.0.0), подменить резолвер
/// (dns), молча опустить туннель до прямого выхода (routing → freedom) или выставить наружу
/// метрики и управление движком. Поэтому перед отдачей движку из записи вырезаются все
/// top-level секции управления ([_kEntryStripSections]), dns/routing кладутся НАШИ (те же,
/// что в десктопной сборке), исходы с тегами direct/block заменяются нашими БЕЗУСЛОВНО,
/// а из входов остаётся только локальный socks на 127.0.0.1 (http-вход записи выбрасывается:
/// Android-плагину нужен только socks — см. engine.dart, туда уходит лишь socksPort, —
/// а чужой http-порт был бы неаутентифицированным локальным прокси через VPN для любого
/// приложения на телефоне).
///
/// Порт socks-входа перезаписываем как раньше: плагин ищет его в конфиге и на него
/// натравливает свой перехватчик трафика.
String xrayEntryConfigJson(SubNode node, {int socksPort = kXraySocksPort}) {
  final full = node.full;
  if (full == null) {
    // Ручной ключ без записи подписки — собираем минимальный конфиг на один узел сами.
    return xrayConfigJsonFromNodes([node], only: node.tag, socksPort: socksPort);
  }
  final cfg = json.decode(json.encode(full)) as Map<String, dynamic>;
  cfg.remove('remarks'); // служебное поле подписки, движку не нужно
  // Чужие секции управления движком — вон. Всё нужное ниже кладём своё.
  for (final s in _kEntryStripSections) {
    cfg.remove(s);
  }
  // DNS — наш (DoH + системный), как в десктопной сборке: серверский резолвер мог бы
  // оказаться резолвером атакующего с полной историей запросов пользователя.
  cfg['dns'] = {'queryStrategy': 'UseIPv4', 'disableCache': false, 'servers': _kDns};
  // Исходы с тегами direct/block из записи выбрасываем БЕЗУСЛОВНО и кладём свои (аудит,
  // HIGH): наши правила ниже шлют geosite:category-ru/private, geoip:ru/private и bittorrent
  // в тег direct — чужой outbound {tag:'direct', protocol:'vless', адрес атакующего}
  // превращал это в молчаливый MITM RU-трафика. Чистим ДО построения routing, чтобы и цель
  // правил (_proxyTagOf) не могла указать на выброшенный исход. Прокси-исход записи
  // (тег 'proxy' у записей нашего сервиса) при этом сохраняется.
  final entryOutbounds = cfg['outbounds'];
  final keptOutbounds = <dynamic>[
    if (entryOutbounds is List)
      for (final o in entryOutbounds)
        if (o is! Map || (o['tag'] != 'direct' && o['tag'] != 'block')) o,
  ];
  keptOutbounds.add({
    'protocol': 'freedom',
    'tag': 'direct',
    'settings': {'domainStrategy': 'UseIPv4'},
  });
  keptOutbounds.add({'protocol': 'blackhole', 'tag': 'block'});
  cfg['outbounds'] = keptOutbounds;
  // Маршрутизация — наша, цель правила — тег прокси-исхода ЭТОЙ записи (у записей нашего
  // сервиса это 'proxy'). Серверский routing мог отправить всё в freedom — молчаливый
  // даунгрейд туннеля до прямого выхода.
  cfg['routing'] = {
    'domainMatcher': 'hybrid',
    'domainStrategy': 'IPIfNonMatch',
    'rules': _rules(false, _proxyTagOf(cfg['outbounds'])),
  };
  // Входы: только локальный socks. http-вход записи выбрасываем целиком (аудит, LOW):
  // плагину нужен только socks (engine.dart передаёт движку лишь socksPort), а чужой
  // http-вход с его портом — неаутентифицированный локальный прокси через VPN для любого
  // приложения на телефоне. Чужой dokodemo-door/vless-вход открыл бы на устройстве
  // публичный прокси, а listen 0.0.0.0 — доступ к нему из локальной сети.
  final clean = <Map<String, dynamic>>[];
  final inbounds = cfg['inbounds'];
  if (inbounds is List) {
    for (final i in inbounds) {
      if (i is! Map) continue;
      final proto = (i['protocol'] ?? '').toString().toLowerCase();
      if (proto != 'socks') continue;
      final m = i.cast<String, dynamic>();
      m['listen'] = '127.0.0.1';
      m['protocol'] = proto;
      clean.add(m);
    }
  }
  // socks-вход обязан быть: плагин ищет его в конфиге и на него натравливает перехватчик.
  if (clean.isEmpty) {
    clean.add({
      'listen': '127.0.0.1',
      'port': socksPort,
      'protocol': 'socks',
      'settings': {'udp': true, 'auth': 'noauth'},
      'sniffing': {'enabled': true, 'destOverride': ['http', 'tls', 'quic'], 'routeOnly': true},
      'tag': 'socks',
    });
  }
  for (final i in clean) {
    i['port'] = socksPort;
  }
  cfg['inbounds'] = clean;
  return const JsonEncoder.withIndent('  ').convert(cfg);
}

/// Top-level секции записи подписки, которые движок НЕ должен получить от сервера (аудит):
/// dns — резолвер атакующего, routing — даунгрейд туннеля до freedom, observatory и
/// burstObservatory — чужой pingConfig (движок исполнял бы его пробы: маячок атакующему
/// с устройства), остальные — логи, метрики и управление движком наружу. Если движку они
/// нужны, мы кладём СВОИ (см. выше), а не серверские.
const List<String> _kEntryStripSections = [
  'dns', 'routing', 'log', 'metrics', 'policy', 'stats', 'transport', 'api', 'reverse',
  'fakedns', 'observatory', 'burstObservatory',
];

/// Тег прокси-исхода записи (vless/vmess/trojan/shadowsocks). У записей нашего сервиса это
/// 'proxy'; у чужой записи берём реальный тег, чтобы правило маршрутизации не ссылалось
/// в никуда.
String _proxyTagOf(dynamic outbounds) {
  if (outbounds is List) {
    for (final o in outbounds) {
      if (o is! Map) continue;
      final proto = (o['protocol'] ?? '').toString().toLowerCase();
      if (['vless', 'vmess', 'trojan', 'shadowsocks'].contains(proto)) {
        final tag = (o['tag'] ?? '').toString();
        return tag.isEmpty ? 'proxy' : tag;
      }
    }
  }
  return 'proxy';
}

/// Тот же конфиг строкой — именно он уходит в движок.
String xrayConfigJsonFromNodes(
  List<SubNode> nodes, {
  String? only,
  int socksPort = kXraySocksPort,
  int? httpPort,
  int? metricsPort,
}) =>
    const JsonEncoder.withIndent('  ').convert(xrayConfigFromNodes(nodes,
        only: only, socksPort: socksPort, httpPort: httpPort, metricsPort: metricsPort));

/// Одиночный share-link (импортированный вручную ключ) → такой же узел, как из подписки.
/// Так у контроллера подключения остаётся ОДИН путь: узлы → конфиг → движок.
/// null — ключ не разобрать ни для одного движка.
SubNode? subNodeFromKey(String key, {String remark = 'Мой ключ'}) {
  final k = key.trim();
  Map<String, dynamic>? singbox;
  try {
    singbox = outboundFromKey(k);
  } catch (_) {
    singbox = null; // напр. Reality без pbk — для sing-box невалиден
  }
  final xray = xrayOutboundFromKey(k);
  if (xray == null && singbox == null) return null;
  // адрес/порт: из xray-версии, иначе из sing-box-версии
  String host = '';
  int port = 443;
  if (xray != null) {
    final settings = (xray['settings'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final list = (settings['vnext'] ?? settings['servers']);
    if (list is List && list.isNotEmpty && list.first is Map) {
      final first = (list.first as Map).cast<String, dynamic>();
      host = (first['address'] ?? '').toString();
      port = first['port'] is int ? first['port'] as int : int.tryParse('${first['port']}') ?? 443;
    }
  } else if (singbox != null) {
    host = (singbox['server'] ?? '').toString();
    port = singbox['server_port'] is int ? singbox['server_port'] as int : 443;
  }
  return SubNode(
    remark: remark,
    tag: remark,
    server: host,
    port: port,
    // если xray-версии нет, кладём пустой объект — узел всё равно отфильтруется движком xray
    xray: xray ?? const <String, dynamic>{},
    singbox: singbox,
  );
}

/// Подписка «списком ссылок» — формат почти всех сторонних сервисов: base64-блоб ИЛИ plain
/// text со строками vless:// vmess:// ss:// trojan://… (по одной на узел, имя — в #фрагменте).
/// Чужие хосты здесь НЕ гейтятся trusted-host'ом: сюда попадает только подписка, которую
/// пользователь импортировал ЯВНО (подтверждение _confirmForeignHost в UI), — иначе отрезалась
/// бы вся сторонняя выдача. Своя (bitaps) выдача идёт строгим путём parseSubscription.
SubParseResult parseLinksSubscription(String body, {String? headerNotice}) {
  var text = body.trim();
  // Сплошная строка без схем — кандидат в base64-блоб (классическая выдача V2Ray/Happ-сервисов).
  if (!text.contains('\n') && !text.contains('://')) {
    try {
      text = utf8.decode(base64.decode(_b64pad(text)));
    } catch (_) {/* не base64 — разбираем как есть */}
  }
  final nodes = <SubNode>[];
  final usedTags = <String>{};
  var skipped = 0;
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (!kSupportedKeySchemes.any((s) => line.toLowerCase().startsWith(s))) {
      skipped++; // не share-link (комментарий, html ошибки, заголовок) — считаем, но не роняем разбор
      continue;
    }
    if (nodes.length >= kSubMaxNodes) {
      skipped++;
      continue;
    }
    // Имя узла — из #фрагмента (percent-decode с фолбэком, как в основном парсере).
    var remark = '';
    final hash = line.lastIndexOf('#');
    if (hash >= 0 && hash + 1 < line.length) {
      final frag = line.substring(hash + 1);
      try {
        remark = Uri.decodeComponent(frag).trim();
      } catch (_) {
        remark = frag.trim();
      }
    }
    final n = subNodeFromKey(line, remark: remark.isEmpty ? 'узел ${nodes.length + 1}' : remark);
    if (n == null) {
      skipped++; // схема знакома, но разобрать не вышло (битый ключ, Reality без pbk)
      continue;
    }
    var tag = n.remark;
    if (usedTags.contains(tag)) {
      var i = 2;
      while (usedTags.contains('$tag $i')) {
        i++;
      }
      tag = '$tag $i';
    }
    usedTags.add(tag);
    if (n.singbox != null) n.singbox!['tag'] = tag;
    nodes.add(SubNode(remark: n.remark, tag: tag, server: n.server, port: n.port, xray: n.xray, singbox: n.singbox));
  }
  return SubParseResult(nodes: nodes, notice: headerNotice, skipped: skipped);
}

String _b64pad(String s) {
  var out = s.replaceAll('-', '+').replaceAll('_', '/').replaceAll(RegExp(r'\s'), '');
  while (out.length % 4 != 0) {
    out += '=';
  }
  return out;
}

/// share-link → outbound в формате xray. Поддержаны схемы, которые реально выдаёт наш сервис
/// и сторонние клиенты: vless (reality/tls, tcp/ws/grpc/httpupgrade), trojan, shadowsocks, vmess.
Map<String, dynamic>? xrayOutboundFromKey(String key) {
  final k = key.trim();
  final scheme = k.split(':').first.toLowerCase();
  final u = Uri.tryParse(k);
  switch (scheme) {
    case 'vless':
      if (u == null || u.host.isEmpty || u.userInfo.isEmpty) return null;
      final q = u.queryParameters;
      final user = <String, dynamic>{'id': Uri.decodeComponent(u.userInfo), 'encryption': 'none'};
      final flow = q['flow'] ?? '';
      if (flow.isNotEmpty) user['flow'] = flow;
      return {
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {'address': u.host, 'port': u.hasPort ? u.port : 443, 'users': [user]},
          ],
        },
        'streamSettings': _streamFromQuery(q, u.host),
      };
    case 'trojan':
      if (u == null || u.host.isEmpty || u.userInfo.isEmpty) return null;
      return {
        'protocol': 'trojan',
        'settings': {
          'servers': [
            {
              'address': u.host,
              'port': u.hasPort ? u.port : 443,
              'password': Uri.decodeComponent(u.userInfo),
            },
          ],
        },
        'streamSettings': _streamFromQuery(u.queryParameters, u.host),
      };
    case 'ss':
      // разбор ss оставляем общему парсеру, а потом переносим поля в формат xray
      final sb = outboundFromKey(k);
      if (sb == null || sb['type'] != 'shadowsocks') return null;
      return {
        'protocol': 'shadowsocks',
        'settings': {
          'servers': [
            {
              'address': sb['server'],
              'port': sb['server_port'],
              'method': sb['method'],
              'password': sb['password'],
            },
          ],
        },
      };
    case 'vmess':
      final sb = outboundFromKey(k);
      if (sb == null || sb['type'] != 'vmess') return null;
      return {
        'protocol': 'vmess',
        'settings': {
          'vnext': [
            {
              'address': sb['server'],
              'port': sb['server_port'],
              'users': [
                {'id': sb['uuid'], 'alterId': sb['alter_id'] ?? 0, 'security': sb['security'] ?? 'auto'},
              ],
            },
          ],
        },
      };
    default:
      return null;
  }
}

/// streamSettings из query-параметров share-link.
Map<String, dynamic> _streamFromQuery(Map<String, String> q, String host) {
  final network = (q['type'] ?? 'tcp').toLowerCase();
  final security = (q['security'] ?? 'none').toLowerCase();
  final ss = <String, dynamic>{'network': network == 'raw' ? 'tcp' : network};
  final fp = (q['fp'] ?? 'chrome');
  if (security == 'reality') {
    ss['security'] = 'reality';
    ss['realitySettings'] = {
      'serverName': q['sni'] ?? host,
      'fingerprint': fp,
      'publicKey': q['pbk'] ?? '',
      if ((q['sid'] ?? '').isNotEmpty) 'shortId': q['sid'],
      'spiderX': '/',
    };
  } else if (security == 'tls' || security == 'xtls') {
    ss['security'] = 'tls';
    ss['tlsSettings'] = {
      'serverName': q['sni'] ?? q['host'] ?? host,
      'fingerprint': fp,
      if ((q['alpn'] ?? '').isNotEmpty) 'alpn': q['alpn']!.split(','),
    };
  }
  switch (ss['network']) {
    case 'ws':
      ss['wsSettings'] = {
        'path': q['path'] ?? '/',
        if ((q['host'] ?? '').isNotEmpty) 'headers': {'Host': q['host']},
      };
      break;
    case 'grpc':
      ss['grpcSettings'] = {'serviceName': q['serviceName'] ?? q['path'] ?? ''};
      break;
    case 'httpupgrade':
      ss['httpupgradeSettings'] = {
        'path': q['path'] ?? '/',
        if ((q['host'] ?? '').isNotEmpty) 'host': q['host'],
      };
      break;
  }
  return ss;
}

/// Правила маршрутизации: российские сайты и приватные адреса — мимо туннеля, реклама — в блок,
/// торренты — напрямую (чтобы не ловить жалобы на выходные ноды), остальное — через узлы.
List<Map<String, dynamic>> _rules(bool balanced, String? pinnedTag) {
  // outboundTag имеет приоритет над balancerTag — ручной выбор сервера выражается им.
  final target = balanced
      ? {'balancerTag': 'gen-bal'}
      : {'outboundTag': pinnedTag ?? 'node-0'};
  return [
    {'type': 'field', 'protocol': ['bittorrent'], 'outboundTag': 'direct'},
    {'type': 'field', 'domain': ['geosite:category-ads-all'], 'outboundTag': 'block'},
    {'type': 'field', 'domain': ['geosite:category-ru', 'geosite:private'], 'outboundTag': 'direct'},
    {'type': 'field', 'ip': ['geoip:ru', 'geoip:private'], 'outboundTag': 'direct'},
    {'type': 'field', 'network': 'tcp,udp', ...target},
  ];
}
