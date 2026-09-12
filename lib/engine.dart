// Единая точка входа к движку туннеля: контроллер подключения не должен знать, чем именно
// поднят туннель на этой платформе.
//
// Две реализации:
//   • ДЕСКТОП (Windows/macOS/Linux) — рядом лежащий xray-core как процесс + системный прокси.
//     xray понимает ВСЕ узлы подписки, включая «белый список» на транспорте xhttp.
//   • ANDROID — тот же xray, но внутри системного VpnService (плагин flutter_v2ray_client):
//     умеет все узлы, включая БС.
//   • iOS — нативной стороны пока нет (заглушка native_tunnel.dart): connect() честно падает
//     с TunnelUnavailable, БС недоступен.
// Если движка нет — честно говорим об этом, а не рисуем фейковое «подключено».

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'android_engine.dart';
import 'desktop_engine.dart';
import 'native_tunnel.dart';
import 'singbox_config.dart';
import 'xray_config.dart';

/// Чем поднимаем туннель на этой платформе.
enum EngineKind {
  /// Процесс xray рядом с приложением (десктоп). Умеет все узлы, включая БС.
  desktopXray,

  /// xray внутри системного VpnService (Android). Тоже умеет все узлы, включая БС.
  androidXray,

  /// Нативная сторона платформы (iOS). Пока не подключена → без БС, connect() бросает.
  native,

  /// Движка нет — туннель поднять нечем.
  none,
}

/// Режим сети по пре-флайту ([TunnelEngine.preflight]).
enum NetProfile {
  /// Не измеряли или измерить не вышло — обычный порядок кандидатов.
  unknown,

  /// Прямые ноды живы (или сравнивать не с чем) — обычный порядок.
  normal,

  /// «Белые списки»: прямые ноды мертвы, а CDN-рельсы (🛡️) живы — кандидатов перебираем
  /// рельсами вперёд, иначе подключение висло бы на мёртвых прямых нодах.
  restricted,
}

/// Классификация сети по фактам пре-флайта. Прямые мертвы + рельсы живы → restricted.
/// Мертвы ВСЕ → unknown: лежит весь интернет, а не «белый список», и перестановка кандидатов
/// тут ничего не спасёт — пусть идёт обычный путь с честной ошибкой.
/// Чистая функция — покрыта restricted_test.
NetProfile classifyNetProfile({required bool directAlive, required bool cdnAlive}) {
  if (!directAlive && cdnAlive) return NetProfile.restricted;
  if (!directAlive) return NetProfile.unknown;
  return NetProfile.normal;
}

/// Состояние туннеля для интерфейса.
class EngineEvent {
  final String state; // connected | disconnected | error
  final int upKbps;
  final int downKbps;
  final String? message;
  const EngineEvent(this.state, {this.upKbps = 0, this.downKbps = 0, this.message});
}

class TunnelEngine {
  TunnelEngine._();
  static final TunnelEngine instance = TunnelEngine._();

  XrayProcess? _proc;
  int? _metricsPort;
  /// Поколение десктоп-подключения: инкрементируется при любой остановке движка
  /// (_stopDesktop/failClosed). Позднее завершение отменённой попытки connect по нему
  /// откатывается (см. _connectDesktop) — иначе туннель-сирота без слушателя.
  int _connectEpoch = 0;
  /// Подписка на статусы NetworkExtension (iOS): живёт от connect() до disconnect().
  StreamSubscription<Map<String, dynamic>>? _nativeSub;
  /// Локальный HTTP-вход поднятого десктоп-туннеля: verifyConnected идёт ЧЕРЕЗ него —
  /// dart:io системный прокси на десктопе игнорирует, и прямой запрос мерил бы мимо туннеля.
  int? _activeHttpPort;
  Timer? _statsTimer;
  (int, int)? _lastTotals;
  final StreamController<EngineEvent> _events = StreamController<EngineEvent>.broadcast();

  Stream<EngineEvent> get events => _events.stream;

  /// Какой движок доступен ЗДЕСЬ И СЕЙЧАС (для десктопа — реально ли лежит бинарь).
  static EngineKind kind() {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return XrayBinary.locate() != null ? EngineKind.desktopXray : EngineKind.none;
    }
    // На Android/iOS наличие нативной стороны проверяется только попыткой вызова —
    // считаем, что она есть, и честно падаем с TunnelUnavailable, если нет.
    if (Platform.isAndroid) return EngineKind.androidXray;
    // iOS: нативная сторона (NetworkExtension) — её ещё предстоит собрать владельцу.
    if (Platform.isIOS) return EngineKind.native;
    return EngineKind.none;
  }

  /// Узлы, которые движок этой платформы реально умеет поднять. У xray — любые,
  /// у sing-box — только те, чей транспорт он понимает (xhttp «белого списка» он не умеет).
  static List<SubNode> usableNodes(List<SubNode> all) =>
      supportsWhitelist ? all : [for (final n in all) if (n.singboxReady) n];

  /// Доступен ли узел «белого списка» (xhttp) на этой платформе.
  static bool get supportsWhitelist =>
      kind() == EngineKind.desktopXray || kind() == EngineKind.androidXray;

  /// Спросить у системы разрешение на VPN — ДО начала отсчёта таймаута подключения.
  ///
  /// Раньше запрос жил внутри connect(), а connect() был обёрнут таймаутом в 40 секунд: пока
  /// человек читал системный диалог «разрешить VPN», таймаут тикал. Кто читал дольше, получал
  /// «Подключение не удалось — таймаут» и при этом ЖИВОЙ туннель, поднявшийся сразу после
  /// разрешения: ключ в шторке есть, а интерфейс говорит «Отключено». Ровно на это и жаловались.
  ///
  /// true — разрешение есть (или платформе оно не нужно), false — человек отказался.
  Future<bool> ensurePermission() async {
    if (kind() == EngineKind.androidXray) return _android.requestPermission();
    return true;
  }

  /// Поднять туннель по узлам подписки. [onlyTag] — если пользователь выбрал сервер вручную.
  /// [keepProxy] — реконнект из блокировки килл-свитча: старый системный прокси НЕ снимаем
  /// (он указывает в мёртвый порт и держит fail-closed), новый SystemProxy.enable перепишет
  /// порты атомарно — без окна голого трафика между «снял» и «поднял».
  /// Бросает [EngineUnavailable] / [TunnelUnavailable] с текстом для пользователя.
  Future<void> connect(List<SubNode> nodes, {String? onlyTag, String server = '', bool keepProxy = false}) async {
    final usable = usableNodes(nodes);
    if (usable.isEmpty) {
      throw EngineUnavailable('в подписке нет узлов, поддерживаемых этой сборкой');
    }
    switch (kind()) {
      case EngineKind.desktopXray:
        await _connectDesktop(usable, onlyTag, keepProxy: keepProxy);
        return;
      case EngineKind.androidXray:
        await _connectAndroid(usable, onlyTag, server);
        return;
      case EngineKind.native:
        // Нативной стороне отдаём конфиг xray с tun-входом (движок — libXray в расширении).
        await NativeTunnel.connect(xrayConfigJsonForIos(usable), server: server);
        // Реальные статусы NetworkExtension проксируем в общий поток: расширение живёт в
        // своём процессе и может умереть в любой момент (краш libXray, смена сети, kill
        // системы) — без этого UI тикал бы «Подключено» при трафике, идущем мимо туннеля.
        _nativeSub?.cancel();
        _nativeSub = NativeTunnel.events().listen((e) {
          final state = e['state']?.toString() ?? '';
          // «connecting» — промежуточное: контроллер принял бы его за обрыв. Остальное
          // честно проксируем: «disconnected»/«error» роняют туннель в UI.
          if (state.isEmpty || state == 'connecting') return;
          _events.add(EngineEvent(state,
              upKbps: (e['up'] as num?)?.toInt() ?? 0,
              downKbps: (e['down'] as num?)?.toInt() ?? 0));
        }, onError: (_) => _events.add(const EngineEvent('disconnected')));
        _events.add(const EngineEvent('connected'));
        return;
      case EngineKind.none:
        throw EngineUnavailable('VPN-движок не установлен в этой сборке');
    }
  }

  Future<void> _connectDesktop(List<SubNode> nodes, String? onlyTag, {bool keepProxy = false}) async {
    // повторный connect не должен плодить процессы. При реконнекте из блокировки (keepProxy)
    // старый прокси НЕ снимаем — иначе между «снял» и «enable переписал» трафик пошёл бы
    // напрямую; блокировку килл-свитча держим до поднятия нового движка.
    await _stopDesktop(disableProxy: !keepProxy);
    // Поколение попытки захватываем ПОСЛЕ остановки: таймаут/отмена/новая попытка снаружи
    // гасят движок (_stopDesktop/failClosed инкрементируют _connectEpoch), а ЭТА попытка
    // могла задержаться (медленный ответ на системный запрос пароля macOS в enable) и
    // доехать позже — без сверки поколения она поднимала «осиротевший» туннель без
    // слушателя поверх состояния новой попытки (багхант, MED).
    final epoch = _connectEpoch;
    final bin = XrayBinary.locate();
    if (bin == null) throw EngineUnavailable('VPN-движок не найден в сборке');
    // Порты берём свободные: фиксированные конфликтуют со вторым запуском и чужими клиентами.
    final socksPort = await _freePort();
    final httpPort = await _freePort();
    final metricsPort = await _freePort();
    final cfg = xrayConfigJsonFromNodes(nodes,
        only: onlyTag, socksPort: socksPort, httpPort: httpPort, metricsPort: metricsPort);
    final proc = await XrayProcess.start(cfg, socksPort: socksPort, binaryPath: bin,
        // Смерть процесса посреди сессии пробрасываем в общий поток событий: без этого десктоп
        // обрыв не замечал вообще (UI тикал «Подключено» при мёртвом туннеле), а контроллер
        // слушает именно этот поток — там обрыв превращается в авто-реконнект/килл-свитч.
        onDied: (p, code) {
          // Гонка с реконнектом: поверх уже поднят новый движок — смерть прежнего не событие.
          if (!identical(_proc, p)) return;
          _events.add(const EngineEvent('disconnected',
              message: 'движок туннеля неожиданно завершил работу'));
        });
    if (epoch != _connectEpoch) { await proc.stop(); return; } // отменили, пока стартовал движок
    final proxyOk = await SystemProxy.enable(socksPort: socksPort, httpPort: httpPort);
    if (!proxyOk) {
      // Прокси мог встать частично (на части сервисов/платформы) — снимаем ДО остановки
      // движка, иначе система остаётся с указателем в порт, который сейчас умрёт.
      // Исключение — реконнект из блокировки (keepProxy): там прокси НЕ снимаем, он и есть
      // fail-closed. Безусловный disable() сбрасывал флаг enabled, и _fail дальше читал это
      // как «блокировки нет» → fail-open при ВКЛЮЧЁННОМ килл-свитче (macOS «Отмена» на
      // запросе пароля — боевой сценарий; багхант, HIGH).
      if (!keepProxy) {
        try { await SystemProxy.disable(); } catch (_) {/* при откате ошибки глотаем */}
      }
      await proc.stop();
      throw EngineUnavailable('не удалось включить системный прокси');
    }
    if (epoch != _connectEpoch) {
      // Позднее завершение отменённой попытки: добиваем процесс и снимаем прокси, ТОЛЬКО
      // если он всё ещё указывает на порты ЭТОЙ попытки — прокси новой попытки, поднятый
      // поверх, трогать нельзя.
      await proc.stop();
      await SystemProxy.disableIfPorts({socksPort, httpPort});
      return;
    }
    _proc = proc;
    _metricsPort = metricsPort;
    _activeHttpPort = httpPort;
    _lastTotals = null;
    _events.add(const EngineEvent('connected'));
    // Реальные счётчики движка раз в секунду → скорость в интерфейсе.
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
  }

  /// Пинги узлов из последнего замера движка (тег outbound'а → мс; null — узел не отвечает).
  Map<String, int?> nodePings = const {};

  final AndroidXrayEngine _android = AndroidXrayEngine();

  /// Жив ли туннель с точки зрения ОС (25.08, исправлено 30.08): VpnService на Android липкий
  /// (переживает свайп-убийство приложения), и новый процесс обязан это узнать — иначе он
  /// стартует с «Отключено» при работающем VPN (баг шестерёнки) и дёргает реконнект.
  /// 30.08: спрашиваем СИСТЕМУ (ConnectivityManager, канал bitaps/system) — проверка через
  /// задержку ядра плагина (connectedDelayAlive) в новом процессе врала «мёртв», потому что
  /// у плагина там нет своего запущенного ядра. Фолбэк на старый способ оставлен.
  Future<bool> tunnelAlive() async {
    if (kind() != EngineKind.androidXray) return false;
    try {
      const ch = MethodChannel('bitaps/system');
      final active = await ch.invokeMethod<bool>('isVpnActive');
      if (active != null) return active;
    } catch (_) {/* канала нет (старая нативка) — пробуем через плагин */}
    try {
      return (await _android.connectedDelayAlive('https://www.gstatic.com/generate_204')) >= 0;
    } catch (_) {
      return false;
    }
  }

  /// Узел, к которому подключаемся на Android. Один — не список: движок там получает готовый
  /// конфиг записи подписки (см. xrayEntryConfigJson).
  SubNode _pickAndroidNode(List<SubNode> nodes, String? onlyTag) {
    if (onlyTag != null) {
      final hit = nodes.where((n) => n.tag == onlyTag);
      if (hit.isNotEmpty) return hit.first;
      throw const FormatException('выбранный сервер отсутствует в подписке');
    }
    // Авто: первый прямой узел (у прямых отклик заведомо ниже, чем у узлов через CDN),
    // иначе просто первый. Пер-узловых замеров на Android нет: конфиг подписки метрик не
    // несёт, а serverDelay живёт на временном экземпляре и результаты сюда не пишет.
    final direct = nodes.where((n) => n.singboxReady);
    return direct.isNotEmpty ? direct.first : nodes.first;
  }

  Future<void> _connectAndroid(List<SubNode> nodes, String? onlyTag, String server) async {
    if (nodes.isEmpty) {
      throw const FormatException('в подписке нет узлов для подключения');
    }
    // Отдаём движку конфиг ОДНОГО узла — ровно тот, что приходит в подписке и работает в
    // сторонних клиентах. Собственная сборка со всеми узлами, балансировщиком и метриками
    // внутри системного VpnService поднимала туннель, но трафик через него не шёл.
    final node = _pickAndroidNode(nodes, onlyTag);
    // Свой порт локального входа: 10808 занимают Happ и v2rayNG, и тогда наш движок не может
    // его открыть — туннель поднимается пустым.
    final cfg = xrayEntryConfigJson(node, socksPort: kXrayAndroidSocksPort);
    await _android.connect(
      cfg,
      remark: server.isEmpty ? node.remark : server,
      onState: (state) {
        // «connected» и «connecting» наверх не поднимаем: о подключении сообщаем сами ниже,
        // а «connecting» контроллер принял бы за обрыв и погасил бы туннель.
        if (state == 'connected' || state == 'connecting') return;
        // Туннель отвалился — вытаскиваем причину из лога движка. Без неё «подключился и сразу
        // отключился» выглядит одинаково для занятого порта, отказа узла и битого конфига,
        // и разбираться приходится вслепую.
        _android.lastError().then((why) {
          _events.add(EngineEvent(state, message: why));
        }, onError: (_) => _events.add(EngineEvent(state)));
      },
    );
    // Метрик xray на Android у нас нет, но скорость несёт сам плагин (V2RayStatus) — шлём
    // её событием 'connected' (контроллер из таких событий берёт только down/up, безопасно).
    _metricsPort = null;
    _lastTotals = null;
    _android.onSpeed = (up, down) => _events.add(EngineEvent('connected', upKbps: up, downKbps: down));
    _events.add(const EngineEvent('connected'));
  }

  Future<void> _pollStats() async {
    final port = _metricsPort;
    // Статистика есть только на десктопе: метрики поднимает наш процесс xray. На Android
    // конфиг подписки метрик не содержит, порт всегда null — счётчиков скорости там нет.
    if (port == null || (kind() == EngineKind.desktopXray && _proc == null)) return;
    final r = await XrayStats.read(port);
    if (r == null) return;
    nodePings = r.pings;
    final prev = _lastTotals;
    _lastTotals = (r.up, r.down);
    if (prev == null) return;
    // байты за секунду → килобиты в секунду (интерфейс ждёт kbps, см. connection.dart)
    final up = ((r.up - prev.$1) * 8 / 1000).round();
    final down = ((r.down - prev.$2) * 8 / 1000).round();
    _events.add(EngineEvent('connected', upKbps: up < 0 ? 0 : up, downKbps: down < 0 ? 0 : down));
  }

  Future<void> disconnect() async {
    switch (kind()) {
      case EngineKind.native:
        await NativeTunnel.disconnect();
        // Подписку на статусы гасим ПОСЛЕ отключения: иначе «disconnected» от собственного
        // disconnect прилетел бы в поток (для слушателя он безвреден — он уже отписался, —
        // но и смысла в нём нет). Пересоздаётся на следующем connect().
        _nativeSub?.cancel();
        _nativeSub = null;
        return;
      case EngineKind.androidXray:
        _statsTimer?.cancel();
        _statsTimer = null;
        _metricsPort = null;
        _lastTotals = null;
        await _android.disconnect();
        return;
      case EngineKind.desktopXray:
      case EngineKind.none:
        await _stopDesktop();
        return;
    }
  }

  /// Неожиданный обрыв при включённом килл-свитче (см. connection.dart): гасим движок, но
  /// НЕ снимаем системный прокси — он указывает в уже мёртвый локальный порт, и трафик,
  /// уважающий системные настройки, умирает вместо того, чтобы молча пойти напрямую
  /// (fail-closed). Килл-свитч ≠ отключение по кнопке: там прокси снимаем всегда (_stopDesktop),
  /// здесь его удержание и есть защита. Снимают блокировку только явные действия человека:
  /// кнопка «Снять блокировку» (unblock), успешный реконнект (SystemProxy.enable в
  /// _connectDesktop атомарно переписывает порты поверх наших — см. keepProxy) или перезапуск
  /// приложения (cleanupStale на старте).
  ///
  /// Только десктоп. На Android после смерти VpnService маршруты удерживает лишь системный
  /// «Постоянный VPN» + «Блокировать соединения без VPN» (настройки ОС — см. диалог тумблера
  /// в Настройках): приложению здесь держать нечего. На iOS fail-closed обеспечивает сам
  /// NetworkExtension через includeAllNetworks (native_ios/AppDelegate.swift).
  Future<void> failClosed() async {
    if (kind() != EngineKind.desktopXray) { await disconnect(); return; }
    _connectEpoch++; // как и _stopDesktop: летящая попытка connect обязана откатиться
    _statsTimer?.cancel();
    _statsTimer = null;
    // Всё как в _stopDesktop, кроме SystemProxy.disable(): прокси намеренно остаётся.
    final p = _proc;
    _proc = null;
    _metricsPort = null;
    _activeHttpPort = null;
    _lastTotals = null;
    if (p != null) await p.stop();
  }

  Future<void> _stopDesktop({bool disableProxy = true}) async {
    _connectEpoch++; // любая остановка инвалидирует летящую попытку connect
    _statsTimer?.cancel();
    _statsTimer = null;
    // Системный прокси снимаем ПЕРВЫМ: если упасть между шагами, лучше остаться без прокси,
    // чем с прокси в уже мёртвый порт (иначе у пользователя пропадёт интернет).
    // Исключение — реконнект из блокировки килл-свитча (disableProxy: false): там прокси
    // держим, новый движок атомарно перепишет порты в SystemProxy.enable, а разрыв
    // «снял → поднял» дал бы секунды голого трафика напрямую.
    if (disableProxy) await SystemProxy.disable();
    final p = _proc;
    _proc = null;
    _metricsPort = null;
    _activeHttpPort = null;
    _lastTotals = null;
    if (p != null) await p.stop();
  }

  /// Свободный локальный порт (нужен и проверке узлов, поэтому не приватный).
  static Future<int> freePort() => _freePort();

  // ── ПРЕ-ФЛАЙТ «ограниченная сеть» (режим «белых списков») ──
  //
  // Зачем. В сетях ТСПУ-режима «белых списков» прямые ноды (сырые IP :8443) заблокированы,
  // а CDN-рельсы «🛡️ … LTE» (cdnXX.bit-core.online:443 за Яндекс CDN) живут — только они
  // и могут подключить. Без детекта автоперебор тратил бы по ~10–15 с на каждую мёртвую
  // прямую ноду, прежде чем дойти до рельсы. Пре-флайт — ОДИН параллельный заход (до 2 с):
  // TCP-connect до 2–3 прямых нод и 1–2 CDN-доменов; прямые мертвы + рельсы живы →
  // restricted, и контроллер подключения перебирает рельсы ПЕРВЫМИ (см. connection.dart и
  // cdnFirst в compareServers). Результат кэшируется на ~60 с — каждый коннект лишними
  // пробами не душим.
  static const Duration preflightTimeout = Duration(seconds: 2);
  static const Duration preflightCacheTtl = Duration(seconds: 60);

  (NetProfile, DateTime)? _preflightCache;

  /// Режим сети по последнему пре-флайту (unknown — ещё не измеряли). Его читает выбор
  /// «лучшего сервера» (cdnFirst), поэтому геттер публичный.
  NetProfile get lastProfile => _preflightCache?.$1 ?? NetProfile.unknown;

  /// Измерить режим сети (с кэшем ~60 с). Никогда не бросает: пре-флайт — подсказка порядку
  /// кандидатов, а не гейт подключения.
  Future<NetProfile> preflight(List<SubNode> nodes) async {
    final cached = _preflightCache;
    if (cached != null && DateTime.now().difference(cached.$2) < preflightCacheTtl) {
      return cached.$1;
    }
    NetProfile profile;
    try {
      profile = await _preflightNow(nodes);
    } catch (_) {
      profile = NetProfile.unknown;
    }
    _preflightCache = (profile, DateTime.now());
    return profile;
  }

  Future<NetProfile> _preflightNow(List<SubNode> nodes) async {
    final direct = [for (final n in nodes) if (!n.isWhitelist && n.server.isNotEmpty) n].take(3).toList();
    final relays = [for (final n in nodes) if (n.isWhitelist && n.server.isNotEmpty) n].take(2).toList();
    // Сравнивать не с чем (нет прямых или нет рельс в выдаче) — обычный порядок.
    if (direct.isEmpty || relays.isEmpty) return NetProfile.normal;
    final alive = await Future.wait([
      for (final n in [...direct, ...relays]) _tcpAlive(n.server, n.port),
    ]);
    return classifyNetProfile(
      directAlive: alive.take(direct.length).any((a) => a),
      cdnAlive: alive.skip(direct.length).any((a) => a),
    );
  }

  static Future<bool> _tcpAlive(String host, int port) async {
    try {
      final s = await Socket.connect(host, port, timeout: preflightTimeout);
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Два gen204 через КОНКРЕТНЫЙ локальный HTTP-вход параллельно (кандидат hot-switch).
  Future<bool> _verifyViaHttpPort(int httpPort) async {
    final results = await Future.wait([
      for (final url in probeUrls) _verifyUrl(url, httpPortOverride: httpPort),
    ]);
    return results.any((ok) => ok);
  }

  // ── HOT-SWITCH: смена узла БЕЗ разрыва VPN (десктоп) ──
  //
  // Плавный переход вместо disconnect→connect: поднимаем ВТОРОЙ процесс движка на НОВЫХ
  // свободных портах с узлом [onlyTag], проверяем его сквозным gen204 (старый туннель в это
  // время работает), и только потом атомарно переписываем системный прокси на новые порты и
  // гасим старый процесс. Окна голого трафика нет вовсе; при провале кандидата старый
  // туннель даже не дёргался — вызывающий остаётся на прежнем сервере (false).

  /// Решение hot-switch: переносить ли системный прокси на порты кандидата. Только если
  /// кандидат подтверждён verify И поколение подключения не сменилось за прогон (отмена/
  /// обрыв/новый connect снаружи). Чистая функция — покрыта hot_switch_test.
  static bool hotSwitchCommits({required bool verified, required int epochBefore, required int epochNow}) =>
      verified && epochBefore == epochNow;

  /// Плавная смена узла на [onlyTag]. true — переключились; false — остались на прежнем
  /// (кандидат не поднялся/не пропустил трафик/сменилось поколение/не тот движок).
  Future<bool> hotSwitch(List<SubNode> nodes, String onlyTag) async {
    if (kind() != EngineKind.desktopXray || _proc == null) return false;
    final usable = usableNodes(nodes);
    if (!usable.any((n) => n.tag == onlyTag)) return false;
    final bin = XrayBinary.locate();
    if (bin == null) return false;
    final epoch = _connectEpoch;
    // Новые свободные порты: старый туннель живёт на своих до самого переключения.
    final socksPort = await _freePort();
    final httpPort = await _freePort();
    final metricsPort = await _freePort();
    final cfg = xrayConfigJsonFromNodes(usable,
        only: onlyTag, socksPort: socksPort, httpPort: httpPort, metricsPort: metricsPort);
    XrayProcess? proc;
    try {
      proc = await XrayProcess.start(cfg, socksPort: socksPort, binaryPath: bin);
    } catch (_) {
      return false;
    }
    final verified = await _verifyViaHttpPort(httpPort);
    if (!hotSwitchCommits(verified: verified, epochBefore: epoch, epochNow: _connectEpoch)) {
      await proc.stop();
      return false;
    }
    // Переписываем системный прокси на новые порты АТОМАРНО. Снимок настроек при этом не
    // затирается: текущий прокси — наш (см. snapshotNeeded в desktop_engine.dart).
    final proxyOk = await SystemProxy.enable(socksPort: socksPort, httpPort: httpPort);
    if (!proxyOk) {
      await proc.stop();
      return false; // старый туннель и старый прокси на месте
    }
    if (epoch != _connectEpoch) {
      // Поколение сменилось за переключение (disconnect снаружи): прокси уже переписан на
      // наши порты — откатываем, старый туннель в любом случае гаснет внешним кодом.
      await proc.stop();
      await SystemProxy.disableIfPorts({socksPort, httpPort});
      return false;
    }
    // Коммит: новый процесс — активный, старый гасим (своя остановка, onDied не сработает).
    final old = _proc;
    _proc = proc;
    _metricsPort = metricsPort;
    _activeHttpPort = httpPort;
    _lastTotals = null; // счётчики нового процесса — с нуля, скорость честно просядет на секунду
    if (old != null) await old.stop();
    return true;
  }

  // ── ПРОВЕРКА УЗЛА: пропускает ли он трафик С ЭТОГО УСТРОЙСТВА ──
  //
  // Смысл: поднять временный экземпляр движка ровно на один узел и вытянуть сквозь него
  // маленький ответ из сети. Дошло — узел настоящий, и число это честное время ответа
  // СКВОЗЬ туннель. Не дошло — узел непригоден, сколько бы его порт ни отвечал на TCP.
  //
  // Что тянем. Свой /gen204 — основной: всегда живой и отдаёт пустой ответ, то есть проверка
  // стоит доли килобайта. Второй адрес — независимый gen204 от Google (gstatic): если наш
  // ориджин прилёг, нельзя объявлять непригодными все узлы разом. Успех = хотя бы один
  // ответил в бюджете.
  static const List<String> probeUrls = [
    'https://origin.bit-core.online/gen204',
    'https://www.gstatic.com/generate_204',
  ];
  // Бюджет на ОДИН узел в замере кнопкой «Пинг»: реальные узлы отвечают за 0.3–1.5 с, четыре
  // секунды — уже «не работает». При параллельном замере (6 одновременно) флот из ~13 узлов
  // укладывается в ~10–12 с общего времени.
  static const Duration probeTimeout = Duration(seconds: 4);

  /// Одновременность замера флота (lanes для runPooled в _pingServers). На десктопе 6 —
  //  шесть процессов xray ок. На Android 2, а не 4: все пробы плагина делят синглтон
  //  V2rayCoreManager с ЖИВЫМ VpnService (нативный сбой убил бы текущее подключение), а
  //  потокобезопасность go-lib measureOutboundDelay по коду плагина не гарантирована
  //  (executor там cachedThreadPool, но это лишь исполнитель). Чистая функция — ping_pool_test.
  static int pingLanes(bool isAndroid) => isAndroid ? 2 : 6;
  // Бюджет одного круга проверки «трафик реально идёт» при подключении (два адреса делят его).
  // Щедрее probeTimeout: отрицательный ответ здесь гонит перебор на следующий сервер.
  static const Duration verifyTimeout = Duration(seconds: 6);

  /// Время ответа сквозь узел в мс, либо null — трафик не пошёл. Никогда не бросает:
  /// непригодный узел это результат проверки, а не сбой приложения.
  /// [lane] — номер полосы параллельного замера: на Android каждая полоса получает СВОЙ
  /// socks-порт временного экземпляра (kXrayProbeSocksPort + lane), иначе два параллельных
  /// probe дрались бы за один порт и один из них молча умирал.
  Future<int?> probe(SubNode node, {int lane = 0}) async {
    try {
      switch (kind()) {
        case EngineKind.androidXray:
          return await _probeAndroid(node, lane);
        case EngineKind.desktopXray:
          return await _probeDesktop(node);
        case EngineKind.native:
        case EngineKind.none:
          return null; // проверять нечем — выдумывать «работает» нельзя
      }
    } catch (_) {
      return null;
    }
  }

  /// Идёт ли трафик сквозь УЖЕ ПОДНЯТЫЙ туннель. Отдельно от [probe]: там временный экземпляр
  /// на конкретный узел, здесь — тот самый туннель, которым сейчас пользуется человек.
  /// Нужна потому, что «подключено» и «работает» — разные вещи: движок поднимается и рапортует
  /// об успехе, а сессию сквозь фильтрацию рвёт, и человек сидит с зелёной кнопкой без интернета.
  Future<bool> verifyConnected() async {
    // Два круга по тем же причинам, что и в probe: рвать человеку рабочее подключение из-за
    // одной не дошедшей проверки нельзя — это было бы хуже, чем не проверять вовсе.
    for (var round = 0; round < 2; round++) {
      if (round > 0) await Future<void>.delayed(const Duration(milliseconds: 700));
      if (await _verifyOnce()) return true;
    }
    return false;
  }

  Future<bool> _verifyOnce() async {
    // Оба адреса опрашиваем ПАРАЛЛЕЛЬНО в одном бюджете verifyTimeout: успех = хотя бы один
    // ответил <400 СКВОЗЬ туннель (не TCP до адреса узла и не пинг — только реальный fetch
    // сквозь него). Последовательный опрос отдавал весь бюджет первому адресу (getUrl/close
    // брали полный left каждый): подвисший origin сжигал всё, gstatic не вызывался никогда,
    // худший verify растягивался до ~25 с, а перебор кандидатов — до минут (багхант, HIGH).
    final results = await Future.wait([
      for (final url in probeUrls) _verifyUrl(url),
    ]);
    return results.any((ok) => ok);
  }

  /// Один gen204 сквозь туннель в бюджете verifyTimeout. Никогда не бросает.
  /// [httpPortOverride] — проверить ЧЕРЕЗ конкретный локальный HTTP-вход (кандидат
  /// hot-switch: он ещё не активен, и _activeHttpPort указывает на прежний туннель).
  Future<bool> _verifyUrl(String url, {int? httpPortOverride}) async {
    try {
      if (kind() == EngineKind.androidXray) {
        final ms = await _android.connectedDelay(url).timeout(verifyTimeout);
        return ms > 0;
      }
      // Десктоп: системный прокси для dart:io не существует (HttpClient его игнорирует) —
      // прямой запрос измерял бы НАШУ сеть, а не туннель. Идём через локальный HTTP-вход
      // поднятого движка. Порта нет (движок не наш/не поднялся) — напрямую НЕ идём: ложный
      // «трафик идёт» при мёртвом туннеле хуже честного «не прошло» (багхант, LOW).
      final httpPort = kind() == EngineKind.desktopXray ? (httpPortOverride ?? _activeHttpPort) : null;
      if (kind() == EngineKind.desktopXray && httpPort == null) return false;
      final client = HttpClient()..connectionTimeout = verifyTimeout;
      if (httpPort != null) client.findProxy = (_) => 'PROXY 127.0.0.1:$httpPort';
      try {
        final req = await client.getUrl(Uri.parse(url)).timeout(verifyTimeout);
        final res = await req.close().timeout(verifyTimeout);
        await res.drain<void>();
        return res.statusCode < 400;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return false;
    }
  }

  Future<int?> _probeAndroid(SubNode node, int lane) async {
    // Свой socks-порт на полосу замера: параллельные probe (lanes=2, см. pingLanes) с одним
    // портом молча мешали бы друг другу.
    final cfg = xrayEntryConfigJson(node, socksPort: kXrayProbeSocksPort + lane);
    // Один круг в общем бюджете probeTimeout: раньше было два (рабочий узел при холодном старте
    // не укладывался в таймаут), но параллельный замер флота не может себе это позволить —
    // приговор ставится по одному подтверждённому отказу, сомнительный узел перепроверяется
    // повторным нажатием «Проверить серверы».
    final deadline = DateTime.now().add(probeTimeout);
    for (final url in probeUrls) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) break;
      try {
        final ms = await _android.serverDelay(cfg, url).timeout(left);
        if (ms > 0) return ms;
      } catch (_) { /* следующий адрес */ }
    }
    return null;
  }

  // Бюджет быстрого замера флота одним процессом: observatory с probeInterval 1с успевает
  // сделать 3–4 круга проб — цель «полный флот ≤5с» из задачи. Непокрытых к дедлайну узлов
  // это касается редко, их добивает per-node фолбэк в вызывающем коде.
  static const Duration fleetProbeBudget = Duration(milliseconds: 4500);

  /// Замер ВСЕГО флота ОДНИМ временным процессом движка (только десктоп): конфиг со всеми
  /// узлами + observatory (см. xrayFleetProbeConfig), покрытие читаем из /debug/vars раз в
  /// 400 мс, пока все узлы не будут замерены или не выйдет бюджет. Возвращает тег узла → мс
  /// (null — узел замерен и НЕ пропускает трафик); узлы, которых обсерватория не успела
  /// замерить, в карте ОТСУТСТВУЮТ — приговор по «нет данных» не выносим, их добивает
  /// per-node фолбэк. null целиком — быстрый путь недоступен (не десктоп/нет бинаря) или
  /// упал: вызывающий идёт прежним per-node перебором (runPooled + probe).
  Future<Map<String, int?>?> probeFleet(List<SubNode> nodes) async {
    if (kind() != EngineKind.desktopXray || nodes.isEmpty) return null;
    final bin = XrayBinary.locate();
    if (bin == null) return null;
    XrayProcess? proc;
    try {
      final socksPort = await _freePort();
      final metricsPort = await _freePort();
      final cfg = xrayFleetProbeConfigJson(nodes, socksPort: socksPort, metricsPort: metricsPort);
      proc = await XrayProcess.start(cfg, socksPort: socksPort, binaryPath: bin);
      final deadline = DateTime.now().add(fleetProbeBudget);
      var covered = <String, int?>{};
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final r = await XrayStats.read(metricsPort);
        if (r == null) continue;
        covered = {
          for (var i = 0; i < nodes.length; i++)
            if (r.pings.containsKey('node-$i')) nodes[i].tag: r.pings['node-$i'],
        };
        if (covered.length >= nodes.length) break; // весь флот замерен — выходим раньше дедлайна
      }
      return covered;
    } catch (_) {
      return null;
    } finally {
      await proc?.stop();
    }
  }

  // На десктопе движок наш собственный: поднимаем процесс на один узел с локальным ВХОДОМ HTTP
  // (HttpClient умеет http-прокси, socks — нет) и тянем канарейку через него.
  Future<int?> _probeDesktop(SubNode node) async {
    final bin = XrayBinary.locate();
    if (bin == null) return null;
    final socksPort = await _freePort();
    final httpPort = await _freePort();
    XrayProcess? proc;
    final client = HttpClient()
      ..connectionTimeout = probeTimeout
      ..findProxy = (_) => 'PROXY 127.0.0.1:$httpPort';
    try {
      final cfg = xrayConfigJsonFromNodes([node], only: node.tag, socksPort: socksPort, httpPort: httpPort);
      proc = await XrayProcess.start(cfg, socksPort: socksPort, binaryPath: bin);
      // Оба адреса делят общий бюджет probeTimeout на узел (см. константу).
      final deadline = DateTime.now().add(probeTimeout);
      for (final url in probeUrls) {
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) break;
        final sw = Stopwatch()..start();
        try {
          final req = await client.getUrl(Uri.parse(url)).timeout(left);
          final res = await req.close().timeout(left);
          await res.drain<void>();
          sw.stop();
          if (res.statusCode < 400) return sw.elapsedMilliseconds.clamp(1, 99999);
        } catch (_) { /* следующий адрес */ }
      }
      return null;
    } finally {
      client.close(force: true);
      await proc?.stop();
    }
  }

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }
}

/// Выполнить [tasks] с ограничением одновременности [lanes]: классический пул воркеров над
/// общей очередью (замер флота — 6 параллельных probe на десктопе: процесс xray на узел,
/// шесть — ок, двадцать — нет). Результаты — по индексам задач. Забор индекса атомарен:
/// между проверкой `next < length` и `next++` нет await, а Dart однопоточен.
/// Чистая механика без движка — покрыта ping_pool_test.
Future<List<T>> runPooled<T>(List<Future<T> Function()> tasks, int lanes) async {
  final results = List<T?>.filled(tasks.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < tasks.length) {
      final i = next++;
      results[i] = await tasks[i]();
    }
  }
  await Future.wait([for (var l = 0; l < lanes && l < tasks.length; l++) worker()]);
  return results.cast();
}
