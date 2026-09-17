import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, File, Directory, Process, ProcessStartMode, exit, stderr;
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_file/open_file.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'singbox_config.dart';
import 'xray_config.dart';
import 'engine.dart';
import 'desktop_engine.dart';
import 'instance_lock.dart';
import 'native_tunnel.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:app_links/app_links.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
// sha256(tgId) → applicationUserName покупки: привязка purchaseToken к аккаунту (сверка на edge).
import 'package:crypto/crypto.dart';

// Приложение разбито на модули; все они — части одной библиотеки (part/part of),
// чтобы приватные имена (_secRead, _load, _conn и т.п.) и extension'ы на ShellState
// оставались доступны между файлами.
part 'i18n.dart';        // локализация RU/EN
part 'theme.dart';       // тема/токены/шрифты
part 'models.dart';      // модели, константы/эндпоинты, токены+secure storage
part 'connection.dart';  // ConnectionController — жизненный цикл VPN-туннеля (вынесен из god-object)
part 'native.dart';      // deep-link (bitaps://), автозапуск при входе, глобальный хоткей — десктоп
part 'widgets.dart';     // painters + общие виджеты-строители
part 'api.dart';         // сетевые вызовы к edge-функциям + сетевые инструменты
part 'node_probe.dart';  // приговоры по узлам: что реально пропускает трафик на этой сети
part 'node_stats.dart';  // публичная статистика доступности нод (спарклайны на «Серверах»)
part 'auto_select.dart'; // автовыбор сервера: скоринг, гистерезис, история коннектов, бэкофф проб
part 'screens/home.dart';
part 'screens/servers.dart';

part 'screens/account.dart';
part 'screens/settings.dart';
part 'screens/lock.dart';
part 'screens/onboarding.dart';
part 'screens/paywall.dart';
part 'screens/billing.dart'; // Play Billing: покупка подписки из приложения (Google Play)
part 'screens/bbox.dart';    // B-box: свой экран товара, предзаказ и «поторопить сборку»

/// SharedPreferences-реализация кэша подписки (сам класс-контракт SubCacheStore — чистый Dart
/// в singbox_config.dart: CI гоняет tool/check_config.dart обычным `dart run`, где dart:ui
/// недоступен, и прямой импорт shared_preferences там ронял гейт — 06.08).
class PrefsSubCacheStore implements SubCacheStore {
  SharedPreferences? _p;
  Future<SharedPreferences?> _prefs() async {
    try {
      return _p ??= await SharedPreferences.getInstance();
    } catch (_) {
      return null; // хранилище недоступно — кэш молча отключён, поведение как у голого fetch
    }
  }

  @override
  Future<String?> read() async {
    try {
      return (await _prefs())?.getString(kSubCachePrefsKey);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String v) async {
    try {
      await (await _prefs())?.setString(kSubCachePrefsKey, v);
    } catch (_) {/* записать не вышло — не критично */}
  }
}

final PrefsSubCacheStore subCacheStore = PrefsSubCacheStore();

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Автозапуск при входе может передать флаг «старт свёрнутым» (launch_at_startup args / OS).
  // Тогда окно не показываем — приложение живёт в трее до клика по иконке.
  final bootMinimized = args.contains('--minimized') || args.contains('--hidden');
  // Тему применяем СИНХРОННО до первого кадра и до WindowOptions: иначе backgroundColor окна
  // читает дефолтную тёмную C.bg, и у пользователей светлой темы мелькает тёмный фон на старте.
  await _applyStoredThemeEarly();
  // window_manager — только десктоп (на Android/iOS его нет → иначе краш на старте)
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    // ОДНА КОПИЯ приложения (аудит п.1): вторая, запущенная при живом VPN первой, доходила бы
    // до cleanupStale ниже и могла снять «наш» прокси при живом туннеле — fail-open. Поэтому
    // блокировка занимается ДО любой уборки: вторая копия просит первую показаться и выходит.
    final inst = await InstanceLock.acquire();
    if (inst.verdict == InstanceVerdict.secondary) {
      stderr.writeln('bitaps VPN уже запущен — активирую открытое окно и выхожу');
      exit(0);
    }
    if (inst.verdict == InstanceVerdict.foreignSquatter) {
      stderr.writeln('порт ${InstanceLock.kInstanceLockPort} занят чужим процессом — '
          'блокировка одной копии недоступна, запускаюсь как есть');
    }
    _instanceLock = inst.lock; // держатель сокета живёт до конца процесса (поле ниже)
    // Прошлый запуск мог завершиться падением/убийством процесса (либо перезагрузкой Windows)
    // с включённым системным прокси — тогда у пользователя «нет интернета» до ручной правки
    // настроек. Прибираем за собой на старте. cleanupStale сам решает по liveness: порт
    // движка слушает — туннель чужой ЖИВОЙ копии, прокси не трогаем; молчит — прокси наш
    // протухший, снимаем и добиваем осиротевший xray (аудит п.3/п.4). Ждём ДО runApp:
    // иначе коннект в первые секунды мог перехватить протухший прокси в «снимок пользователя».
    final stale = await SystemProxy.cleanupStale(instanceLockHeld: inst.lock != null);
    if (stale == StaleCleanup.keptAlive) {
      stderr.writeln('обнаружен живой туннель другой копии — системный прокси не трогаю');
    }
    await windowManager.ensureInitialized();
    // Просьба второй копии «поднимись»: окно уже инициализировано — показываем и фокусируем.
    _instanceLock?.onRaise = () async {
      try { await windowManager.setSkipTaskbar(false); } catch (_) {}
      try { await windowManager.show(); await windowManager.focus(); } catch (_) {}
    };
    // hotkey_manager требует сброса «залипших» с прошлого запуска хоткеев на старте (десктоп).
    // fail-soft: на платформе без нативной стороны бросит — глотаем, живём без хоткея.
    try { await hotKeyManager.unregisterAll(); } catch (_) {}
    // Десктоп больше не «растянутый телефон» 440px: окно по умолчанию широкое (виден боковой
    // рейл навигации, см. LayoutBuilder в _buildBody), максимума нет — ресайз свободный.
    // Узкое окно (<720) продолжает работать мобильной раскладкой с нижним таб-баром.
    // Отладочный размер окна: BITAPS_WIN=ШИРИНАxВЫСОТА. Нужен, чтобы проверять МОБИЛЬНУЮ
    // раскладку (<720) на десктопе — иначе телефонные экраны нечем посмотреть без устройства.
    // В release ветка мертва (kDebugMode == false) и выкидывается компилятором.
    Size winSize = const Size(1024, 800);
    if (kDebugMode) {
      final m = RegExp(r'^(\d{3,4})x(\d{3,4})$').firstMatch(Platform.environment['BITAPS_WIN'] ?? '');
      if (m != null) winSize = Size(double.parse(m.group(1)!), double.parse(m.group(2)!));
    }
    final opts = WindowOptions(
      size: winSize,
      minimumSize: const Size(360, 640),
      center: true,
      backgroundColor: C.bg, // уже согласован с сохранённой темой (см. _applyStoredThemeEarly)
      title: 'bitaps VPN',
    );
    windowManager.waitUntilReadyToShow(opts, () async {
      if (bootMinimized) {
        // старт свёрнутым: окно не показываем (только трей); skipTaskbar чтобы не мигало в доке/панели
        try { await windowManager.setSkipTaskbar(true); } catch (_) {}
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    });
  }
  runApp(const BitApp());
  _maybeStartShotLoop();
}

// ── Самопроверка визуала (ТОЛЬКО debug) ──
// screencapture/CGWindowListCreateImage требуют TCC-разрешение «запись экрана», которого у
// автоматизации нет → в debug-сборке с env BITAPS_SHOT=<папка> приложение раз в 2 секунды
// сохраняет PNG собственного кадра (RepaintBoundary поверх MaterialApp). В release kDebugMode
// == false → вся ветка мертва и выкидывается компилятором; на поведение приложения не влияет.
final GlobalKey _shotKey = GlobalKey();

/// Держатель блокировки одной копии (десктоп): сокет занят в main() до windowManager
/// и живёт до выхода процесса — освобождает его ОС. null на мобильных и при чужом
/// процессе на порту блокировки.
InstanceLock? _instanceLock;

void _maybeStartShotLoop() {
  if (!kDebugMode) return;
  final dir = Platform.environment['BITAPS_SHOT'];
  if (dir == null || dir.isEmpty) return;
  Timer.periodic(const Duration(seconds: 2), (_) async {
    try {
      final ro = _shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (ro == null) return;
      final img = await ro.toImage(pixelRatio: 2);
      final bytes = await img.toByteData(format: ImageByteFormat.png);
      if (bytes != null) File('$dir/shot.png').writeAsBytesSync(bytes.buffer.asUint8List());
    } catch (e) {
      debugPrint('shot loop: $e');
    }
  });
}

// Прочитать сохранённые тему И акцент и применить их ДО runApp/окна.
// Дешёвое чтение SharedPreferences; при любой ошибке молча остаёмся на дефолте, старт не блокируем.
Future<void> _applyStoredThemeEarly() async {
  try {
    final p = await SharedPreferences.getInstance();
    final tm = (p.getInt('themeMode') ?? 0).clamp(0, 2);
    // Акцент тоже применяем ДО первого кадра (зеркалит _load): иначе у сменившего акцент
    // юзера первые кадры рисуются дефолтным Sunset-оранжевым и скачком перекрашиваются.
    final ai = (p.getInt('accent') ?? 0).clamp(0, accentThemes.length - 1);
    final th = accentThemes[ai];
    C.accent = th.$2;
    C.accentSoft = th.$3;
    // Секретный «Фосфор» форсит люминофорную палитру ДО первого кадра (иначе мелькает обычный фон).
    if (ai == kPhosphorAccent) {
      C.applyTheme(false, phosphorOn: true);
      return;
    }
    final light = tm == 1 ||
        (tm == 2 &&
            WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.light);
    C.applyTheme(light);
  } catch (_) {
    // не удалось прочитать настройку — оставляем дефолтную тему, окно всё равно откроется
  }
}

// ============================ APP ============================
class BitApp extends StatelessWidget {
  const BitApp({super.key});
  @override
  Widget build(BuildContext context) {
    // Тема реактивна: слушаем глобальный флаг яркости (обновляется из C.applyTheme при смене
    // темы/системной яркости) и перестраиваем ThemeData целиком. `home: const Shell()` сохраняет
    // ShellState между пересборками MaterialApp (тот же тип виджета → State не пересоздаётся).
    return ValueListenableBuilder<bool>(
      valueListenable: themeLight,
      // RepaintBoundary(_shotKey) — для debug-самоскриншотов (см. _maybeStartShotLoop);
      // в release просто лишний no-op слой поверх корня.
      builder: (_, light, __) => RepaintBoundary(key: _shotKey, child: MaterialApp(
        title: 'bitaps VPN',
        debugShowCheckedModeBanner: false,
        theme: _appTheme(light),
        home: const Shell(),
      )),
    );
  }

  ThemeData _appTheme(bool light) => ThemeData(
        brightness: light ? Brightness.light : Brightness.dark,
        scaffoldBackgroundColor: C.bg,
        colorScheme: light
            ? ColorScheme.light(primary: C.accent, surface: C.bg2)
            : ColorScheme.dark(primary: C.accent, surface: C.bg2),
        useMaterial3: true,
        fontFamily: 'SpaceGrotesk',
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => ShellState();
}

class ShellState extends State<Shell> with TickerProviderStateMixin, WidgetsBindingObserver, TrayListener, WindowListener {
  int tab = 0;
  int mode = 0;
  Server server = kNoServer;
  /// Почему список серверов пуст: текст от сервиса выдачи («Лимит устройств исчерпан»,
  /// «Подписка истекла»). Без него экран молча показывал бы пустоту, и человек не понимал бы,
  /// что делать.
  String? subNotice;
  /// Узлы из подписки — источник правды для списка серверов и для подключения.
  List<SubNode> subNodes = const [];
  /// Когда сервис выдачи в последний раз УСПЕШНО отдал список узлов. Нужен экрану «Серверы»:
  /// при открытии он подтягивает список, только если прошло >5 мин (см. _maybeRefreshNodes).
  DateTime? nodesFetchedAt;
  /// Публичная статистика доступности нод (спарклайны внизу «Серверов»): последний удачный
  /// отчёт, момент его загрузки (троттлинг 5 мин) и признак сбоя — по нему вместо графика
  /// показываем честную строку «данные недоступны», страница не ломается.
  NodeStatsReport? nodeStats;
  DateTime? nodeStatsFetchedAt;
  bool nodeStatsFailed = false;
  bool _statsLoading = false; // re-entrancy-гвард загрузки статистики
  Timer? _statsTimer; // периодическое обновление, пока открыта вкладка «Серверы»
  Timer? _autoTimer;  // фон-цикл автовыбора: пересчёт лучшего, дозамер просроченных, миграция
  DateTime? _lastAutoMigrateAt; // анти-маятник мягкой миграции туннеля (auto_select.dart)
  // Учёт успеха/сбоя сессии для истории узлов: прежнее состояние conn из слушателя _conn,
  // узел и момент старта текущей сессии (ранний обрыв — это сбой узла, а не «нормально»).
  int _prevConn = 0;
  String _sessionNodeId = '';
  DateTime? _sessionStartedAt;
  Timer? _updTimer;   // проверка обновлений раз в 6 ч по ходу сессии (26.08)
  /// Список узлов сейчас показан ИЗ КЭША (выдача недоступна — сеть в режиме «белых списков»):
  /// дата того успешного ответа. null — свежая выдача из сети. Экран «Серверы» показывает
  /// пометку «список из кэша от <дата>» — молча подменять свежий список старым нельзя.
  DateTime? subCacheAt;
  bool tgl1 = false, tgl2 = true, tgl3 = true, tgl4 = false;
  /// Килл-свитч: при НЕОЖИДАННОМ обрыве VPN трафик блокируется (fail-closed), а не идёт
  /// напрямую мимо туннеля. По умолчанию ВЫКЛ — блокировка интернета не должна случаться
  /// без ведома человека. Само состояние блокировки живёт в _conn.blocked и не персистится.
  bool killSwitch = false;
  /// Автопереподключение: после НЕОЖИДАННОГО обрыва сами переподключаемся с нарастающей
  /// паузой (2/5/15/30 с, дальше каждые 60 с). По умолчанию ВКЛ — тумблер и есть согласие
  /// человека; выключил — после обрыва остаёмся отключёнными, как раньше.
  bool autoReconnect = true;
  String? appPin; // PIN блокировки приложения
  bool _locked = false;
  final TextEditingController _pinCtrl = TextEditingController();
  int _pinFails = 0;       // подряд неверных попыток PIN (сбрасывается при успехе)
  int _pinLockSecs = 0;    // >0 → ввод PIN временно заблокирован на это число секунд
  Timer? _pinLockTimer;    // тикает обратный отсчёт блокировки
  int accentIdx = 0, btnStyle = 0;
  int themeMode = 0; // 0 тёмная · 1 светлая · 2 системная
  bool autoConnect = false;
  // «VPN всегда включён» (30.08, владелец): Android — BootReceiver поднимает последний туннель
  // после перезагрузки телефона; десктоп — автозапуск с системой + авто-подключение. Юзеру
  // после включения настройки вообще не нужно заходить в приложение.
  bool alwaysOn = false;
  /// Демо-сессия там, где туннель поднять нечем (тумблер в Настройках, по умолчанию ВЫКЛ).
  /// Раньше демо включалось само и молча — оплативший человек видел «подключено» без туннеля.
  bool demoMode = false;
  // Режим «лучший сервер»: при подключении сами берём оптимальный сервер (ползунок на Главной).
  // Выбор конкретного сервера в списке выключает режим (см. _pickServer).
  bool bestServer = true;
  // Ручной выбор сервера, сохранённый до загрузки узлов: парк на старте пуст, поэтому
  // применяем его в _applyNodes, когда узлы подписки реально придут.
  String? _pendingServerId;
  // Живые замеры отклика (кнопка «Пинг» на Серверах): id сервера → мс. Пока замера не было —
  // показываем статичный s.ping из models.dart. Не персистим: замер живёт в рамках сессии.
  final Map<String, int> pingMeasured = {};
  /// Приговоры по узлам: пропускает ли узел трафик С ЭТОГО устройства. Заполняет проверка
  /// серверов, живут между запусками (prefs), привязаны к сети — см. node_probe.dart.
  final Map<String, NodeVerdict> nodeVerdicts = {};
  /// Долгая память по узлам: успехи/сбои коннектов и серии неудачных проб (auto_select.dart).
  /// Приговор живёт 30 минут и привязан к сети, а история учит автовыбор на неделях: узел,
  /// систематически рвущий соединение, штрафуется и после истечения свежего приговора.
  final Map<String, NodeHistory> nodeHist = {};
  /// Отпечаток текущей сети: две первые группы внешнего адреса. Домашний Wi-Fi и мобильный
  /// оператор блокируют по-разному, и приговор с одной сети нельзя показывать на другой.
  String netId = '';
  bool _pinging = false; // идёт замер пинга — гвард от двойного запуска
  /// Прогресс замера «Проверить серверы»: сколько узлов уже проверено и сколько всего
  /// (показывается на кнопке «готово X из Y» — иначе параллельный замер флота выглядел бы
  /// зависшим на ~10 секунд).
  int pingDone = 0, pingTotal = 0;
  String keyStr = kDemoKey;
  String? customCfg;
  String? importedHost;
  // Идентификатор устройства для подписки (заголовок x-hwid). Создаётся один раз при первом
  // запуске и живёт в prefs: по нему сервис считает устройства в лимите тарифа.
  String hwid = '';
  final TextEditingController _support = TextEditingController();
  // Куда ответить на обращение (почта или @ник): без него заявка из приложения уходила
  // с пустым контактом, и ответить человеку было физически некуда.
  final TextEditingController _supportContact = TextEditingController();
  final Set<String> favs = {};
  // вход / подписка / устройства (реальные данные из Supabase)
  int? tgId;
  String? appToken, subPlan, subExpires, subName;
  String? loginSecret; // код входа (отдельный от vpn_key credential) — для входа в приложение/кабинет
  int? subLimit;
  bool subActive = false;
  bool _subLoading = false; // re-entrancy-гвард _refreshSub (в т.ч. тихий фоновый рефреш)
  bool _subVisibleLoading = false; // спиннеры/дизейбл в UI — ТОЛЬКО для явного (не silent) рефреша
  bool _pairing = false; // идёт авто-вход через бота — гвард от двойного тапа (два диалога подряд)
  bool _toolBusy = false; // идёт сетевой инструмент (спид-тест/утечки) — гвард от двойного запуска
  bool _supportSending = false; // идёт отправка в поддержку — гвард от двойной отправки
  bool _loggingIn = false; // идёт вход по ключу — гвард от двойного входа
  bool _rotating = false; // идёт ротация «Кода входа» — гвард от двойного тапа (два POST)
  List<Map<String, dynamic>> devices = [];
  /// app-sub не смог получить список устройств с хаба (devices_unknown): показывать
  /// «не удалось получить список», а не «устройств нет» — разница принципиальная.
  bool devicesUnknown = false;
  final TextEditingController _loginCtrl = TextEditingController();
  bool get loggedIn => tgId != null && appToken != null;

  // Подключение вынесено в ConnectionController (см. connection.dart) — состояние и логика туннеля
  // больше не живут в ShellState. Ниже тонкие прокси, чтобы экраны читали conn/hms/скорость как раньше.
  late final ConnectionController _conn;
  int get conn => _conn.conn;
  String get hms => _conn.hms;
  int get down => _conn.down;
  int get up => _conn.up;
  int get sessions => _conn.sessions;
  /// Причина последней неудачи подключения и предлагаемое действие — карточка на Главной.
  String? get connFail => _conn.failMsg;
  ConnFix get connFix => _conn.failFix;
  /// VPN отвалился при включённом килл-свитче — трафик заблокирован (fail-closed):
  /// на Главной показываем карточку блокировки вместо «Отключено», см. home.dart.
  bool get connBlocked => _conn.blocked;
  /// Идёт горячая смена сервера без разрыва VPN (десктоп, hotSwitch): на время переключения
  /// список серверов показывает «переключаюсь на …», повторные тапы игнорируются.
  bool hotSwitching = false;
  String hotSwitchTarget = '';
  void toggle() async {
    // Режим «лучший сервер» — по замеру по ТВОЕЙ сети: перед коннектом убеждаемся, что у
    // лучшего кандидата есть СВЕЖИЙ живой замер (а не просто лучший по статистике хаба).
    // Свежий есть — коннектим сразу; протух/нет — дозамеряем просроченные узлы и лишь потом идём.
    if (bestServer && _conn.conn == 0) {
      await _probeFreshForConnect();
      setState(_repickBest);
    }
    _conn.toggle();
  }

  /// Свежесть живого замера кандидата для коннекта: вердикт ok и моложе 2 минут. Лучший свежий —
  /// задержки в коннекте нет; иначе дозамеряем просроченных перед стартом (по твоей сети, не хабу).
  Future<void> _probeFreshForConnect() async {
    if (!bestServer) return;
    final now = DateTime.now();
    const fresh = Duration(minutes: 2);
    bool freshTag(String tag) {
      final v = nodeVerdicts[tag];
      return v != null && v.ok && now.difference(v.at) < fresh;
    }
    final cand = serverForMode(mode);
    if (cand.id.isNotEmpty && freshTag(cand.id)) return;
    final stale = [for (final n in subNodes) if (n.server.isNotEmpty && !freshTag(n.tag)) n.tag];
    if (stale.isNotEmpty) await _pingServers(silent: true, onlyTags: stale.toSet());
  }

  // Анимации НЕ гоняем безусловно (..repeat()) — это жгло батарею: starfield + шестерёнка + кольца
  // перерисовывались каждый кадр на всех вкладках и даже в фоне. Теперь _syncAnimations() держит
  // каждый контроллер запущенным ТОЛЬКО когда он реально виден (нужная вкладка + приложение активно).
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 6));
  late final AnimationController _wave =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  late final AnimationController _twinkle =
      AnimationController(vsync: this, duration: const Duration(seconds: 4));
  bool _foreground = true; // окно ВИДИМО (не свёрнуто); расфокус (inactive) — тоже видимо, см. lifecycle

  // Запускать/останавливать анимации по факту видимости — экономит CPU/GPU/батарею.
  // Вызывается пост-фрейм из build() (ловит смену вкладки/темы/стиля/подключения) и из lifecycle.
  void _syncAnimations() {
    // не гоняем, если свёрнуто, заблокировано или поверх экрана онбординг (анимации не видны)
    final vis = _foreground && !_locked && !_showOnboarding;
    final onHome = tab == 0;
    _drive(_twinkle, vis && onHome && !C.light);         // звёзды: только Главная, тёмная тема
    _drive(_spin, vis && onHome && btnStyle == 0);        // шестерёнка: только Главная, стиль по умолчанию
    _drive(_wave, vis && onHome && (conn == 2 || btnStyle == 3)); // кольца: когда реально показаны
  }

  void _drive(AnimationController c, bool on) {
    if (on && !c.isAnimating) {
      c.repeat();
    } else if (!on && c.isAnimating) {
      c.stop();
    }
  }

  // Публичная обёртка над setState для extension-файлов (api/screens/widgets): они не наследники
  // State, поэтому прямой setState даёт analyzer-warning invalid_use_of_protected_member. Обёртка
  // закрывает это без большого рефактора god-object. mounted — публичный геттер, его звать можно.
  void rebuild([VoidCallback? fn]) { if (mounted) setState(fn ?? () {}); }

  // ----- онбординг (первый запуск / «Показать знакомство» в Настройках) -----
  bool _showOnboarding = false; // поверх всего UI (после PIN-замка)
  int _onbPage = 0;
  final PageController _onbCtrl = PageController();

  // ----- статистика аккаунта из app-sub (fail-soft: null → в карточке прочерк) -----
  String? statMemberSince; // ISO-дата первого события аккаунта
  int? statPaidDays, statRefs, statTokens;
  int subStreak = 0, subNextBonus = 0; // стрик продлений + бонус за СЛЕДУЮЩЕЕ раннее продление
  bool subVip = false;

  // ----- tray (десктоп): иконка в меню-баре/трее, показать/скрыть окно -----
  bool _trayReady = false;
  // Пара (conn, blocked), под которую последний раз пересобрано трей-меню (анти-спам).
  // blocked меняется БЕЗ смены conn (unblock/_fail килл-свитча) — по одному conn меню врало:
  // после «Снять блокировку» в трее горело «Трафик заблокирован».
  (int, bool)? _lastTrayState;

  // ----- автозапуск (десктоп): «запускать при входе» + «старт свёрнутым» -----
  bool autoLaunch = false;   // приложение стартует при входе в систему
  bool startMinimized = false; // при автозапуске окно не показываем (только трей)

  // ----- глобальный хоткей подключения (десктоп) -----
  String hotkeyStr = kDefaultHotkey; // сериализованный хоткей (persist prefs)
  bool _recordingHotkey = false;     // рекордер в Настройках ждёт нажатия
  HotKey? _registeredHotkey;         // текущий зарегистрированный (для unregister при смене)

  // ----- секретная тема «Фосфор» -----
  bool phosphorUnlocked = false; // свотч Phosphor виден в Настройках
  int _logoTaps = 0;             // счётчик тапов по мини-лого шапки (пасхалка)
  DateTime? _lastLogoTap;        // сброс серии, если между тапами >1.2с

  // ----- deep-link (bitaps://): приём кастомной схемы -----
  // Подписку держим в поле — она удерживает AppLinks живым и отменяется в dispose.
  StreamSubscription<Uri>? _linkSub;
  // Ссылка, пришедшая под PIN-замком: исполняем после разблокировки, а не поверх него.
  Uri? _pendingDeepLink;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _conn = ConnectionController(
      keyOf: () => keyStr,
      hwidOf: () => hwid,
      serverOf: () => server,
      onNodes: _applyNodes,
      // Даже в режиме «лучший сервер» движок получает КОНКРЕТНЫЙ узел — тот же, что показан на
      // экране. Выбор делает интерфейс (serverForMode), движок его исполняет: стартовый кандидат
      // ставит toggle() (best → serverForMode), следующих при автопереборе контроллер просит
      // через nextServerOf — после свежего приговора это уже другой узел.
      bestServerOn: () => bestServer,
      nextServerOf: () {
        rebuild(() => server = serverForMode(mode));
        return server;
      },
      dropAlertOn: () => tgl2,
      trafWarnOn: () => tgl4,
      killSwitchOn: () => killSwitch,
      reconnectOn: () => autoReconnect,
      demoOn: () => demoMode,
      // Узел не пропустил трафик: помечаем его тут же, чтобы он перестал считаться доступным
      // и не был выбран «лучшим» на следующем подключении. Плюс сбой в долгую историю узла —
      // автовыбор будет штрафовать его и после того, как свежий приговор истечёт.
      onNodeDead: (tag) {
        if (tag.isEmpty) return;
        rebuild(() {
          nodeVerdicts[tag] = NodeVerdict(ok: false, at: DateTime.now(), net: netId);
          pingMeasured.remove(tag);
          (nodeHist[tag] ??= NodeHistory()).recordFail();
          if (bestServer) server = serverForMode(mode);
        });
        _saveVerdicts();
        _saveHistory();
      },
      onToast: _toast,
      onPersist: _save,
      onSpin: _spinConn,
    );
    // conn мог смениться (подключение/обрыв/таймер) → пересобираем И сверяем анимации здесь,
    // а не пост-фреймом на каждый build (см. _syncAnimations вызовы у мутаторов tab/тема/стиль).
    // !_locked: при замке build() отдаёт _lockScreen(), который conn/hms/скорость не читает —
    // посекундный тик таймера сессии не должен впустую перестраивать экран блокировки.
    _conn.addListener(() {
      _trackSessionOutcome(); // обучение автовыбора: успех/ранний обрыв сессии → nodeHist
      if (mounted && !_locked) {
        setState(() {});
        _syncAnimations();
        // трей-меню пересобираем ТОЛЬКО при смене пары (conn, blocked), а не на каждый тик таймера
        final trayState = (_conn.conn, _conn.blocked);
        if (trayState != _lastTrayState) { _lastTrayState = trayState; _refreshTray(); }
      }
    });
    _load();
    _checkUpdate();
    // 26.08 (владелец): проверка обновлений не только на старте, но и по ходу сессии —
    // раз в 6 ч. Диалог по-прежнему раз на запуск; с включённым автообновлением сборка
    // подтягивается сама в фоне, хоть приложение и не закрывалось неделю.
    _updTimer = Timer.periodic(const Duration(hours: 6), (_) => _checkUpdate());
    // Play Billing (Android): поднимаем purchaseStream и кэш цен заранее, чтобы пейвол
    // открывался с готовыми ценами магазина. Fail-soft — без Play-сервисов просто выключен.
    _initBilling();
    // Tray — только десктоп; вся инициализация fail-soft (без нативной стороны/библиотеки
    // приложение просто живёт без трея, не падая).
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) _initTray();
    // закрытие окна крестиком/Alt+F4: гасим туннель до выхода (см. onWindowClose ниже)
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.addListener(this);
      // Удерживаем окно при просьбе закрыться: без preventClose процесс мог умереть раньше,
      // чем reg.exe допишет снятие прокси из onWindowClose — и человек оставался бы без
      // интернета (прокси в мёртвый порт). Отпускаем сами после уборки (аудит п.2).
      unawaited(() async {
        try { await windowManager.setPreventClose(true); } catch (_) {}
      }());
    }
    // deep-link (bitaps://) — все платформы; автозапуск+хоткей — только десктоп. Всё fail-soft.
    _initDeepLinks();
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) _initNativeDesktop();
    // Статистика доступности нод: периодическое обновление, пока открыта вкладка «Серверы»
    // (внутри троттлинг 5 мин — сеть не дёргаем впустую на других вкладках).
    _statsTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (mounted && tab == 1 && !_locked) _maybeRefreshNodeStats();
    });
    // Фон-цикл автовыбора (auto_select.dart): пересчёт лучшего с гистерезисом, дозамер
    // просроченных узлов с бэкоффом, детект смены сети и (десктоп) мягкая миграция
    // деградировавшего туннеля. Внутри всё привязано к форграунду/состоянию — тик дешёвый.
    _autoTimer = Timer.periodic(kAutoSelectTick, (_) => _autoTick());
    // Одноразовый пост-фрейм: первичная сверка анимаций после первого кадра (дальше — событийно).
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _syncAnimations(); });
  }

  // ---------------- TRAY (десктоп) ----------------
  Future<void> _initTray() async {
    try {
      // ассет-пути (tray_manager сам резолвит их в data/flutter_assets); Windows требует .ico
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/tray.ico' : 'assets/tray.png',
        // macOS: template-иконка перекрашивается системой под светлый/тёмный меню-бар
        isTemplate: Platform.isMacOS,
      );
      await _updateTrayMenu();
      // setToolTip не реализован на Linux (метод бросает) — зовём только там, где поддержан
      if (!Platform.isLinux) await trayManager.setToolTip('bitaps VPN');
      trayManager.addListener(this);
      _trayReady = true;
    } catch (e) {
      debugPrint('tray init failed: $e'); // нет libayatana/нативной стороны → живём без трея
    }
  }

  // Меню трея = мини-пульт: статус (демо-гейт как везде), подключить/отключить, дни подписки,
  // режимы, окно, выход. Пересобираем при смене языка (_langChip) И при смене состояния —
  // подключения/подписки/режима (см. _refreshTray, зовём из слушателя _conn и _applySub/_save).
  Future<void> _updateTrayMenu() async {
    try {
      // строка статуса — тот же honesty-гейт, что и на Главной: в демо не пишем «Подключено»,
      // а при сработавшем килл-свитче — не «Отключено», а факт блокировки
      final statusLabel = conn == 0
          ? (connBlocked ? tr('Трафик заблокирован') : tr('Отключено'))
          : conn == 1
              ? tr('Подключение…')
              : (gEngineReal ? tr('Подключено') : tr('Демо-режим'));
      // дни подписки в меню (если вошёл и знаем срок)
      final days = _trayDaysLeft();
      final subLabel = !loggedIn
          ? tr('Не вошёл')
          : (days != null
              ? (appLang == 'en' ? '$days days left' : 'осталось $days ${_trayPluralDays(days)}')
              : (subActive ? tr('Подписка активна') : tr('Подписка неактивна')));
      final connected = conn == 2;
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'status', label: '● $statusLabel', disabled: true),
        MenuItem(key: 'sub', label: '  $subLabel', disabled: true),
        MenuItem.separator(),
        // одна строка-тумблер: подключить при отключённом, отключить при активном
        MenuItem(key: 'toggle', label: connected ? tr('Отключить') : tr('Подключить')),
        // подменю выбора режима (Авто/Стрим/Игры/Прив.)
        MenuItem.submenu(
          key: 'mode',
          label: tr('Режим'),
          submenu: Menu(items: [
            for (int i = 0; i < modeLabels.length; i++)
              MenuItem.checkbox(key: 'mode_$i', label: tr(modeLabels[i]), checked: mode == i),
          ]),
        ),
        MenuItem.separator(),
        MenuItem(key: 'show', label: tr('Открыть bitaps')),
        MenuItem(key: 'quit', label: tr('Выйти из bitaps')),
      ]));
    } catch (e) {
      debugPrint('tray menu failed: $e');
    }
  }

  // Пересобрать меню трея под текущее состояние (fail-soft; только если трей готов).
  void _refreshTray() { if (_trayReady) _updateTrayMenu(); }

  // дни до конца подписки для меню трея (дублирует логику account._daysLeft, но без extension-зависимости)
  int? _trayDaysLeft() {
    if (subExpires == null) return null;
    final e = DateTime.tryParse(subExpires!);
    if (e == null) return null;
    final d = (e.toUtc().difference(DateTime.now().toUtc()).inMinutes / 1440).ceil();
    return d < 0 ? 0 : d;
  }

  String _trayPluralDays(int n) {
    final n10 = n % 10, n100 = n % 100;
    if (n10 == 1 && n100 != 11) return 'день';
    if (n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14)) return 'дня';
    return 'дней';
  }

  @override
  void onTrayIconMouseDown() {
    // macOS-конвенция: клик по иконке меню-бара открывает меню; Win/Linux — тумблер окна
    if (Platform.isMacOS) {
      trayManager.popUpContextMenu();
    } else {
      _toggleWindowVisible();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    final key = menuItem.key;
    switch (key) {
      case 'show':
        // старт-свёрнутым мог поставить skipTaskbar — снимаем при явном открытии
        try { await windowManager.setSkipTaskbar(false); } catch (_) {}
        await windowManager.show();
        await windowManager.focus();
        break;
      case 'hide':
        await windowManager.hide();
        break;
      case 'toggle':
        // тот же ConnectionController.toggle, что у большой кнопки и хоткея
        toggle();
        _refreshTray();
        break;
      case 'quit':
        // Перед выходом обязательно гасим туннель: _stopDesktop снимает системный прокси
        // ПЕРВЫМ, иначе после закрытия приложения у пользователя остался бы прокси в мёртвый
        // порт и «пропавший интернет». Сбой disconnect выход не блокирует.
        try { _conn.reset(); await TunnelEngine.instance.disconnect(); } catch (_) {}
        // сначала убираем иконку из трея, затем закрываем окно/процесс
        try { await trayManager.destroy(); } catch (_) {}
        await windowManager.destroy();
        break;
      default:
        // выбор режима из подменю (mode_0..mode_3): только при отключённом туннеле (как _modeChip)
        if (key != null && key.startsWith('mode_')) {
          final i = int.tryParse(key.substring(5));
          if (i == null || i < 0 || i >= modeLabels.length) return;
          if (conn != 0) { _toast(tr('Отключись, чтобы сменить режим')); return; }
          setState(() { mode = i; bestServer = true; server = serverForMode(i); });
          _save();
          _refreshTray();
        }
    }
  }

  // Крестик/Alt+F4: окно удержано (setPreventClose в initState) — сначала гасим туннель
  // (прокси снимается ПЕРВЫМ, см. _stopDesktop) и только потом отпускаем закрытие. Жёсткий
  // таймаут: сбой/зависание disconnect выход блокировать не должно — отпускаем как есть.
  @override
  void onWindowClose() async {
    try {
      _conn.reset();
      await TunnelEngine.instance.disconnect().timeout(const Duration(seconds: 8));
    } catch (_) {/* туннель мог уже быть погашен — закрываемся всё равно */}
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      exit(0); // плагин отказал — роняем процесс сами; туннель к этому моменту уже погашен
    }
  }

  Future<void> _toggleWindowVisible() async {
    try {
      if (await windowManager.isVisible()) {
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    } catch (e) {
      debugPrint('tray toggle window failed: $e');
    }
  }

  // крутить кнопку-шестерёнку: быстро во время коннекта, спокойно в покое/при обрыве.
  // Меняем скорость и перезапускаем ТОЛЬКО если шестерёнка сейчас видна — иначе просто
  // запоминаем длительность (её подхватит _syncAnimations, когда вернёмся на Главную).
  void _spinConn(bool fast) {
    _spin.duration = Duration(milliseconds: fast ? 1400 : 6000);
    _spin.stop();
    if (_foreground && !_locked && tab == 0 && btnStyle == 0) _spin.repeat();
  }

  // Android доставляет deep-link ДВАЖДЫ: плагину app_links (там мы его и разбираем — см.
  // _handleDeepLink) и отдельно в навигацию Flutter, как будто это имя маршрута. Именованных
  // маршрутов у нас нет, поэтому второй путь падал: «Null check operator used on a null value»
  // внутри _onUnknownRoute. Внешне это выглядело так, что по ссылке из автонастройки приложение
  // открывается, но ключ не подставляется — на уже запущенном приложении импорт просто не доходил.
  // На УЖЕ ЗАПУЩЕННОМ приложении ссылка приходит ТОЛЬКО сюда — поток app_links её не отдаёт
  // (проверено на устройстве: вкладка не переключалась, импорт не происходил). Поэтому здесь не
  // просто гасим навигацию, а разбираем ссылку сами тем же обработчиком.
  // Возвращаем true всегда = «обработали»: именованных маршрутов у приложения нет, и любая
  // попытка Flutter перейти по «маршруту» заканчивалась падением.
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    final uri = routeInformation.uri;
    if (uri.scheme.toLowerCase() == kUrlScheme) _handleDeepLink(uri);
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // авто-замок при сворачивании. paused (мобильный) + hidden (десктоп свёрнут). НЕ inactive —
    // он срабатывает на ЛЮБУЮ потерю фокуса (в т.ч. открытие внешней ссылки) и ложно блокировал бы.
    final bg = state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    // inactive = потеря фокуса при ВИДИМОМ окне (клик в браузер/Telegram, в т.ч. наша же ссылка
    // пейринга) — анимации не гасим, иначе шестерёнка/кольца замирают на полукадре и окно
    // выглядит зависшим. Фон для анимаций — только paused/hidden/detached (свёрнуто/скрыто).
    _foreground = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    _syncAnimations(); // свернули → гасим анимации; вернулись → поднимаем нужные
    // Возврат из фона (напр. после оплаты в браузере/боте): тихо подтягиваем подписку —
    // статус мог смениться, пока приложение стояло. Гвард _subLoading внутри _refreshSub.
    if (state == AppLifecycleState.resumed && loggedIn) _refreshSub(silent: true);
    if (bg && tgl1 && (appPin?.isNotEmpty ?? false) && !_locked) {
      setState(() => _locked = true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_trayReady) trayManager.removeListener(this);
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) windowManager.removeListener(this);
    _linkSub?.cancel();
    _disposeHotkey();
    _onbCtrl.dispose();
    _pinLockTimer?.cancel();
    _statsTimer?.cancel();
    _autoTimer?.cancel();
    _updTimer?.cancel();
    _conn.dispose();
    _spin.dispose();
    _wave.dispose();
    _twinkle.dispose();
    _support.dispose();
    _supportContact.dispose();
    _loginCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  // ----- persistence: настройки реально сохраняются между запусками -----
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    // секреты читаем из secure storage ДО setState (там нельзя await); с миграцией/фолбэком внутри
    final secPin = await _secRead(p, 'appPin');
    final secKey = await _secRead(p, 'key');
    final secToken = await _secRead(p, 'appToken');
    final secLogin = await _secRead(p, 'loginSecret');
    final secCfg = await _secRead(p, 'cfg'); // «Свой конфиг» может нести vless-ключ → тоже в secure storage
    // троттлинг PIN переживает рестарт: счётчик ошибок + время окончания локаута (epoch ms)
    final secPinFails = await _secRead(p, 'pinFails');
    final secPinLockUntil = await _secRead(p, 'pinLockUntil');
    // hwid для подписки: создаём при первом запуске и сразу пишем в prefs — не в _save, иначе
    // до первого сохранения настроек каждый запуск занимал бы новый слот устройства.
    var hw = p.getString('hwid') ?? '';
    if (hw.length < 10) {
      hw = genHwid();
      await p.setString('hwid', hw);
    }
    if (!mounted) return;
    // язык: сохранённый выбор, иначе автоопределение по системной локали (ru → ru, иначе en)
    final savedLang = p.getString('lang');
    appLang = savedLang ??
        (WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'ru' ? 'ru' : 'en');
    setState(() {
      phosphorUnlocked = p.getBool('phosphorUnlocked') ?? false;
      // Секретную «Фосфор» можно восстановить, ТОЛЬКО если она уже разблокирована — иначе
      // потерянный флаг оставил бы выбранным недоступный акцент. Клампим к обычным палитрам.
      final maxAccent = phosphorUnlocked ? accentThemes.length - 1 : kPhosphorAccent - 1;
      accentIdx = (p.getInt('accent') ?? 0).clamp(0, maxAccent);
      autoLaunch = p.getBool('autoLaunch') ?? false;
      startMinimized = p.getBool('startMinimized') ?? false;
      hotkeyStr = p.getString('hotkey') ?? kDefaultHotkey;
      btnStyle = (p.getInt('btnStyle') ?? 0).clamp(0, btnStyleNames.length - 1);
      mode = (p.getInt('mode') ?? 0).clamp(0, modeLabels.length - 1);
      themeMode = (p.getInt('themeMode') ?? 0).clamp(0, 2);
      autoConnect = p.getBool('autoConnect') ?? false;
      alwaysOn = p.getBool('alwaysOn') ?? false;
      demoMode = p.getBool('demoMode') ?? false;
      // Приговоры по узлам переживают перезапуск: иначе после каждого открытия приложения
      // человек снова видел бы прочерки и заново гонял проверку.
      netId = p.getString('netId') ?? '';
      final vraw = p.getString('nodeVerdicts');
      if (vraw != null && vraw.isNotEmpty) {
        try {
          final m = jsonDecode(vraw);
          if (m is Map) {
            for (final e in m.entries) {
              final v = NodeVerdict.fromJson(e.value);
              if (v != null) nodeVerdicts['${e.key}'] = v;
            }
          }
        } catch (_) { /* испорченная запись — просто проверим заново */ }
      }
      // Долгая история узлов (успехи/сбои коннектов, бэкофф проб) — обучение автовыбора.
      final hraw = p.getString('nodeHist');
      if (hraw != null && hraw.isNotEmpty) {
        try {
          final m = jsonDecode(hraw);
          if (m is Map) {
            for (final e in m.entries) {
              final h = NodeHistory.fromJson(e.value);
              if (h != null) nodeHist['${e.key}'] = h;
            }
          }
        } catch (_) { /* испорченная запись — история накопится заново */ }
      }
      bestServer = p.getBool('bestServer') ?? true;
      tgl1 = p.getBool('tgl1') ?? false;
      appPin = secPin;
      _pinFails = int.tryParse(secPinFails ?? '') ?? 0; // восстанавливаем счётчик ошибок PIN
      tgl2 = p.getBool('tgl2') ?? true;
      tgl3 = p.getBool('tgl3') ?? true;
      tgl4 = p.getBool('tgl4') ?? false;
      killSwitch = p.getBool('killSwitch') ?? false;
      autoReconnect = p.getBool('autoReconnect') ?? true; // по умолчанию ВКЛ (см. поле)
      _conn.sessions = p.getInt('sessions') ?? 0;
      customCfg = secCfg;
      keyStr = secKey ?? kDemoKey;
      hwid = hw;
      importedHost = p.getString('host');
      tgId = p.getInt('tgId');
      appToken = secToken;
      loginSecret = secLogin;
      subPlan = p.getString('subPlan');
      subExpires = p.getString('subExpires');
      subName = p.getString('subName');
      subLimit = p.getInt('subLimit');
      subActive = p.getBool('subActive') ?? false;
      // статистика аккаунта: кэш прошлой сессии, чтобы карточка не мигала прочерками до рефреша
      statMemberSince = p.getString('stMember');
      statPaidDays = p.getInt('stDays');
      statRefs = p.getInt('stRefs');
      statTokens = p.getInt('stTokens');
      subStreak = p.getInt('stStreak') ?? 0;
      subNextBonus = p.getInt('stNextBonus') ?? 0;
      subVip = p.getBool('stVip') ?? false;
      // онбординг: показываем при первом запуске; уже залогиненных (обновившихся) не трогаем —
      // им знакомство доступно из Настроек («Показать знакомство»)
      _showOnboarding = !(p.getBool('seen_onboarding') ?? false) && !loggedIn;
      try {
        final dl = jsonDecode(p.getString('devices') ?? '[]');
        devices = (dl is List) ? dl.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : [];
      } catch (e) {
        debugPrint('cached devices decode error: $e');
        devices = [];
      }
      favs
        ..clear()
        ..addAll(p.getStringList('favs') ?? const []);
      final th = accentThemes[accentIdx];
      C.accent = th.$2;
      C.accentSoft = th.$3;
      _applyThemeMode();
      tab = loggedIn ? 0 : 2; // не вошёл → сразу экран входа (Кабинет), а не демо-главная
      _locked = tgl1 && (appPin?.isNotEmpty ?? false);
      server = serverForMode(mode); // сервер согласован с сохранённым режимом (без рассинхрона)
      // Ползунок «лучший сервер» выключен → восстанавливаем РУЧНОЙ выбор пользователя (serverId),
      // иначе после рестарта плашка говорила бы «сервер выбираешь ты», а стоял бы автоподобранный.
      // Фолбэк на serverForMode выше, если сохранённый сервер исчез/стал недоступен.
      if (!bestServer) {
        // Парк узлов на старте ещё пуст — запоминаем выбор и применяем его в _applyNodes,
        // когда подписка подтянется; иначе первая же загрузка узлов затирала ручной выбор авто.
        _pendingServerId = p.getString('serverId');
        final match = fleet.where((s) => s.id == _pendingServerId && s.available);
        if (match.isNotEmpty) server = match.first;
      }
    });
    _syncAnimations(); // применили тему/вкладку/стиль из хранилища → сверяем анимации разом
    // если на прошлой сессии перебор PIN оставил активный локаут — доигрываем оставшийся отсчёт,
    // чтобы блокировка ввода пережила рестарт (иначе перезапуск сбрасывал троттлинг мгновенно).
    if (_locked) {
      final lockUntil = int.tryParse(secPinLockUntil ?? '') ?? 0;
      final remainMs = lockUntil - DateTime.now().millisecondsSinceEpoch;
      if (remainMs > 0) _startPinLock((remainMs / 1000).ceil().clamp(1, 60));
    }
    // Тест-сессия для визуальной самопроверки (ТОЛЬКО debug, зеркало BITAPS_SHOT): env
    // BITAPS_TEST_TG + BITAPS_TEST_TOKEN подставляют вход без ручного ввода — экраны кабинета
    // можно скринить автоматикой. В release kDebugMode==false → ветка мертва и выкидывается.
    if (kDebugMode) {
      final ttg = int.tryParse(Platform.environment['BITAPS_TEST_TG'] ?? '');
      final ttok = Platform.environment['BITAPS_TEST_TOKEN'];
      if (ttg != null && ttok != null && ttok.isNotEmpty) {
        setState(() { tgId = ttg; appToken = ttok; tab = 2; });
      }
    }
    if (loggedIn) _refreshSub(silent: true);
    _loadNodes(); // узлы подписки для экрана «Серверы» — до первого подключения
    // Авто-коннект НЕ должен подниматься сквозь блокировку или без логина: если экран заблокирован
    // (_locked) — стартуем после разблокировки (см. _tryUnlock), иначе пробуем сразу.
    // ПОРЯДОК ВАЖЕН (30.08): сначала усыновление живого туннеля, авто-коннект — только если
    // туннеля не оказалось. Раньше они шли одновременно: автоконнект детонировал через 500 мс,
    // не дожидаясь проверки, — и переподключал уже работающий VPN.
    if (!_locked) {
      _recoverOrphanedConnection().then((adopted) {
        if (!adopted) _maybeAutoConnect();
      });
    }
  }

  // Поднять авто-коннект, только если он включён, туннель выключен, экран разблокирован и есть логин.
  void _maybeAutoConnect() {
    if (!autoConnect || conn != 0 || _locked || !loggedIn) return;
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted && autoConnect && conn == 0 && !_locked && loggedIn) toggle();
    });
  }

  /// Старт приложения при уже живом нашем следе в системе, но без живой сессии в этом процессе
  /// (свайп-убийство/перезагрузка). Возвращает true, если туннель жив и сессия усыновлена
  /// (авто-коннект тогда НЕ запускаем — владелец: возврат в приложение не должен дёргать
  /// реконнект рабочего VPN). Десктоп: след — наш системный прокси, а движок — наш процесс:
  /// прокси жив без движка = движок умер → честный реконнект (true — подключение пошло).
  Future<bool> _recoverOrphanedConnection() async {
    if (!kRealTunnel) return false;
    if (_locked || conn != 0) return false;
    final kind = TunnelEngine.kind();
    if (kind == EngineKind.desktopXray) {
      try {
        if (!await SystemProxy.looksOurs()) return false;
      } catch (_) {
        return false;
      }
      if (!mounted || conn != 0 || _locked) return false;
      _toast(tr('Соединение потеряно — переподключаюсь…'));
      toggle(); // десктоп: движок — наш процесс, прокси жив без него = он умер, честный реконнект
      return true;
    }
    if (kind == EngineKind.androidXray) {
      bool alive;
      try {
        alive = await TunnelEngine.instance.tunnelAlive();
      } catch (_) {
        alive = false;
      }
      if (!alive || !mounted || conn != 0 || _locked) return false;
      // 30.08 (владелец): туннель ЖИВ — НЕ реконнектим, а усыновляем. Раньше тут был
      // безусловный toggle(): «закрыл вкладку → открыл — а оно переподключается», хотя VPN
      // и так работал. Теперь интерфейс просто честно показывает текущий туннель.
      if (bestServer) setState(_repickBest);
      _conn.adoptRunningTunnel();
      return true;
    }
    return false;
  }

  // тема: 0 тёмная · 1 светлая · 2 системная (следует за настройкой ОС).
  // Секретный акцент «Фосфор» (accentIdx == kPhosphorAccent) форсит люминофорную тёмную палитру
  // независимо от режима яркости — она сама по себе законченная тема.
  void _applyThemeMode() {
    if (accentIdx == kPhosphorAccent) { C.applyTheme(false, phosphorOn: true); return; }
    final light = themeMode == 1 ||
        (themeMode == 2 &&
            WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.light);
    C.applyTheme(light);
  }

  @override
  void didChangePlatformBrightness() {
    // системная тема сменилась в ОС — подхватываем на лету, если выбран режим «Системная»
    if (themeMode == 2 && mounted) { setState(_applyThemeMode); _syncAnimations(); } // starfield только в тёмной
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('accent', accentIdx);
    await p.setBool('phosphorUnlocked', phosphorUnlocked);
    await p.setBool('autoLaunch', autoLaunch);
    await p.setBool('startMinimized', startMinimized);
    await p.setString('hotkey', hotkeyStr);
    await p.setInt('btnStyle', btnStyle);
    await p.setInt('mode', mode);
    await p.setInt('themeMode', themeMode);
    await p.setString('lang', appLang);
    await p.setBool('autoConnect', autoConnect);
    await p.setBool('alwaysOn', alwaysOn);
    await p.setBool('demoMode', demoMode);
    await p.setBool('bestServer', bestServer);
    await p.setString('serverId', server.id); // ручной выбор восстанавливаем в _load при bestServer=false
    await p.setBool('tgl1', tgl1);
    await _secWrite(p, 'appPin', appPin);
    await p.setBool('tgl2', tgl2);
    await p.setBool('tgl3', tgl3);
    await p.setBool('tgl4', tgl4);
    await p.setBool('killSwitch', killSwitch);
    await p.setBool('autoReconnect', autoReconnect);
    await p.setInt('sessions', sessions);
    await p.setStringList('favs', favs.toList());
    await _secWrite(p, 'cfg', customCfg); // secure storage (может нести vless-ключ), не plaintext
    await _secWrite(p, 'key', keyStr);
    if (tgId != null) { await p.setInt('tgId', tgId!); } else { await p.remove('tgId'); }
    await _secWrite(p, 'appToken', appToken);
    await _secWrite(p, 'loginSecret', loginSecret);
    // при null — УДАЛЯЕМ ключ (иначе после logout остаются данные прежней подписки в prefs)
    if (subPlan != null) { await p.setString('subPlan', subPlan!); } else { await p.remove('subPlan'); }
    if (subExpires != null) { await p.setString('subExpires', subExpires!); } else { await p.remove('subExpires'); }
    if (subName != null) { await p.setString('subName', subName!); } else { await p.remove('subName'); }
    if (subLimit != null) { await p.setInt('subLimit', subLimit!); } else { await p.remove('subLimit'); }
    await p.setBool('subActive', subActive);
    // статистика аккаунта (кэш для карточки «// статистика»; null — удаляем, как и поля подписки)
    if (statMemberSince != null) { await p.setString('stMember', statMemberSince!); } else { await p.remove('stMember'); }
    if (statPaidDays != null) { await p.setInt('stDays', statPaidDays!); } else { await p.remove('stDays'); }
    if (statRefs != null) { await p.setInt('stRefs', statRefs!); } else { await p.remove('stRefs'); }
    if (statTokens != null) { await p.setInt('stTokens', statTokens!); } else { await p.remove('stTokens'); }
    await p.setInt('stStreak', subStreak);
    await p.setInt('stNextBonus', subNextBonus);
    await p.setBool('stVip', subVip);
    await p.setString('devices', jsonEncode(devices));
    if (importedHost != null) {
      await p.setString('host', importedHost!);
    } else {
      await p.remove('host');
    }
  }

  // Пинг сервера: живой замер кнопкой «Пинг»; при его отсутствии и поднятом туннеле — живой
  // пинг из observatory движка (обновляется раз в секунду вместе со статами, отдельный таймер
  // не нужен); иначе статичный s.ping из models.dart (0 — «не замерено»).
  int pingOf(Server s) => pingMeasured[s.id] ?? (conn == 2 ? _observatoryPing(s.id) : null) ?? s.ping;

  /// Пинг узла из observatory движка (null — движок его не видит/узел молчит). Тег outbound'а
  /// в конфиге — 'node-<индекс>' по месту узла в подписке (см. xray_config.dart), поэтому мапим
  /// через индекс в subNodes. На Android замера нет вовсе (конфиг подписки метрик не несёт).
  int? _observatoryPing(String nodeTag) {
    final idx = subNodes.indexWhere((n) => n.tag == nodeTag);
    if (idx < 0) return null;
    final ms = TunnelEngine.instance.nodePings['node-$idx'];
    return (ms != null && ms > 0) ? ms : null;
  }

  /// Доступные серверы — ТОЛЬКО узлы подписки. Запасного списка нет намеренно: пустой экран
  /// с объяснением честнее, чем выдуманные серверы, к которым нельзя подключиться.
  /// Что мы знаем про узел на ЭТОЙ сети.
  NodeState stateOf(String tag) {
    final v = nodeVerdicts[tag];
    if (v == null || !v.fresh || (netId.isNotEmpty && v.net.isNotEmpty && v.net != netId)) {
      return NodeState.unknown;
    }
    return v.ok ? NodeState.works : NodeState.blocked;
  }

  List<Server> get fleet => [
        for (final n in subNodes)
          serverFromSubNode(n, ping: pingMeasured[n.tag] ?? 0)
              // Узел, через который трафик не идёт, выбирать нечего: гасим его в списке так же,
              // как «скоро». Иначе человек жмёт зелёную строку и получает мёртвое подключение —
              // ровно то, на что жаловался владелец во время глушения интернета.
              .copyWith(available: stateOf(n.tag) != NodeState.blocked),
      ];

  /// Применить свежий список узлов: обновляем парк и следим, чтобы выбранный сервер
  /// существовал (иначе подключение ушло бы к исчезнувшему узлу). [cacheAt] — дата кэша,
  /// из которого поднят список; null — выдача из сети, пометка кэша затирается.
  void _applyNodes(List<SubNode> ns, {DateTime? cacheAt}) {
    if (!mounted || ns.isEmpty) return;
    rebuild(() {
      subNodes = ns;
      subCacheAt = cacheAt;
      // Отложенный ручной выбор (serverId, сохранённый до загрузки узлов): сервер ещё есть
      // в свежем парке — возвращаем его; нет — обычный авто-подбор ниже.
      final pending = _pendingServerId;
      if (!bestServer && pending != null) {
        _pendingServerId = null;
        final hit = fleet.where((s) => s.id == pending && s.available);
        if (hit.isNotEmpty) { server = hit.first; return; }
      }
      if (bestServer) {
        // Автовыбор — с гистерезисом: новая выдача сама по себе не повод менять показанный
        // сервер; исчезнувший/заблокированный текущий _repickBest заменит безусловно.
        _repickBest();
      } else if (!fleet.any((s) => s.id == server.id)) {
        server = serverForMode(mode);
      }
    });
  }

  int _betterServer(Server a, Server b) =>
      compareServers(a, b, pingOf, stateOf: (s) => stateOf(s.id),
          // Restricted-сеть (пре-флайт): рельсы вперёд, прямые в конец — иначе «лучший сервер»
          // и автоперебор начинали бы с заведомо мёртвых прямых нод.
          cdnFirst: TunnelEngine.instance.lastProfile == NetProfile.restricted);

  // ── Скоринг автовыбора (auto_select.dart) ──

  /// Запись /public/stats, соответствующая серверу списка (null — хаб его не меряет: CDN-рельсы).
  NodeStat? _statFor(Server s) {
    final n = subNodes.where((x) => x.tag == s.id);
    if (n.isEmpty) return null;
    return matchNodeStat(nodeStats?.nodes, server: n.first.server, remark: n.first.remark);
  }

  /// Взвешенный скор сервера для режима [m]: живой пинг + джиттер/стабильность из серии хаба +
  /// история коннектов + штрафы (мёртв по хабу, CDN в обычной сети). Меньше = лучше.
  double _scoreOf(Server s, int m) {
    final stat = _statFor(s);
    final rep = nodeStats;
    final insight = insightOf(stat,
        nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        statsAge: rep != null ? DateTime.now().difference(rep.generatedAt.toLocal()) : Duration.zero);
    return autoScore(
      pingMs: pingOf(s),
      jitterMs: insight.jitterMs,
      stability: insight.stability,
      statsRtt: stat?.rttNow,
      statsDead: insight.dead,
      histPenalty: nodeHist[s.id]?.historyPenalty(DateTime.now()) ?? 0,
      isCdn: s.proto.startsWith('LTE'),
      mode: m,
    );
  }

  /// Сравнение для автовыбора: ранг приговора сильнее любого скора (мёртвый узел не выиграет
  /// у живого ни при каких цифрах), в restricted — рельсы вперёд (как cdnFirst в compareServers),
  /// затем скор; при равенстве — прежний тай-брейк compareServers, чтобы порядок был стабильным.
  int _scoreCompare(Server a, Server b, int m) {
    int rank(Server s) => switch (stateOf(s.id)) {
          NodeState.works => 0,
          NodeState.unknown => 1,
          NodeState.blocked => 2,
        };
    final ra = rank(a), rb = rank(b);
    if (ra != rb) return ra.compareTo(rb);
    if (TunnelEngine.instance.lastProfile == NetProfile.restricted) {
      final ca = a.proto.startsWith('LTE') ? 0 : 1, cb = b.proto.startsWith('LTE') ? 0 : 1;
      if (ca != cb) return ca.compareTo(cb);
    }
    final sa = _scoreOf(a, m), sb = _scoreOf(b, m);
    if (sa != sb) return sa.compareTo(sb);
    return compareServers(a, b, pingOf, stateOf: (s) => stateOf(s.id));
  }

  // Режим реально подбирает сервер: Стрим→мин.нагрузка/стабильность, Игры→мин.джиттер,
  // Авто→баланс, Прив→зарубежный прямой (иначе лучший). Выбор — по скору (_scoreCompare).
  Server serverForMode(int m) {
    var avail = fleet.where((s) => s.available).toList();
    if (avail.isEmpty) {
      // Все узлы помечены «недоступными» (stale-приговоры после сбоя сети: замеры писались
      // в момент обрыва и пережили его). Авто-режим обязан ВСЁ РАВНО пробовать — приговор это
      // замер прошлого момента, а не диагноз; иначе автоподключение молча умирало, пока
      // человек вручную не нажмёт «проверить серверы» (инцидент владельца 30.08).
      avail = fleet.toList();
      if (avail.isEmpty) return kNoServer;
    }
    // Нагрузку узлов подписка не сообщает (у всех 0) — тогда «Стрим» сортировал список
    // произвольно. Есть настоящие цифры — сортируем по ним, нет — по скору (стабильность
    // серии в нём для Стрима весит больше всего, см. modeWeights).
    if (m == 1 && avail.any((s) => s.load > 0)) {
      avail.sort((a, b) => a.load.compareTo(b.load));
      return avail.first;
    }
    if (m == 3) {
      // Приватность: зарубежный узел. Страны у узлов подписки нет (country пуст) — фильтр по
      // ней был мёртвым кодом со времён выдуманного списка и RU-ноду («Мск · оффлоад») мог
      // выбрать даже «Прив.». Судим по названию узла — оно и есть страна в выдаче.
      final intl = avail.where((s) => s.city != 'Россия').toList();
      if (intl.isNotEmpty) {
        intl.sort((a, b) => _scoreCompare(a, b, m));
        return intl.first;
      }
    }
    avail.sort((a, b) => _scoreCompare(a, b, m));
    return avail.first;
  }

  /// Пересчитать «лучший» С ГИСТЕРЕЗИСОМ: текущий выбранный сервер держим, пока кандидат не
  /// лучше его разительно (shouldSwitchBest) — иначе соседние по отклику узлы перетягивали бы
  /// звание от каждого замера, и карточка сервера «прыгала». Текущий невалиден (исчез из
  /// выдачи/заблокирован) — переключаемся безусловно. [force] — осознанное действие человека
  /// (смена режима/включение ползунка): там пересчитываем честно, без удержания.
  void _repickBest({bool force = false}) {
    final cand = serverForMode(mode);
    if (cand.id.isEmpty || cand.id == server.id) return;
    final curValid = !force &&
        server.id.isNotEmpty &&
        fleet.any((s) => s.id == server.id && s.available) &&
        stateOf(server.id) != NodeState.blocked;
    if (curValid && !shouldSwitchBest(_scoreOf(server, mode), _scoreOf(cand, mode), curValid: true)) {
      return; // разница в пределах гистерезиса — держим текущий, карточка не дребезжит
    }
    server = cand;
  }

  /// Обучение автовыбора на фактах сессий (зовётся из слушателя _conn ДО setState-ветки):
  /// вход в «Подключено» — verify коннекта прошёл, узлу +успех; выход из «Подключено» в
  /// первую минуту сессии — узел подвёл (ранний обрыв), +сбой. Долгие сессии дополнительного
  /// успеха не дают: факт «прожил час» уже виден по отсутствию сбоя.
  void _trackSessionOutcome() {
    final c = _conn.conn;
    if (c == 2 && _prevConn != 2) {
      _sessionNodeId = server.id;
      _sessionStartedAt = DateTime.now();
      if (_sessionNodeId.isNotEmpty) {
        (nodeHist[_sessionNodeId] ??= NodeHistory()).recordOk();
        _saveHistory();
      }
    } else if (c == 0 && _prevConn == 2) {
      final started = _sessionStartedAt;
      if (_sessionNodeId.isNotEmpty &&
          started != null &&
          DateTime.now().difference(started) < const Duration(minutes: 1)) {
        (nodeHist[_sessionNodeId] ??= NodeHistory()).recordFail();
        _saveHistory();
      }
      _sessionNodeId = '';
      _sessionStartedAt = null;
    }
    _prevConn = c;
  }

  /// Сохранить историю узлов. Отдельно от общего _save (тот синхронен с UI и част), как
  /// _saveVerdicts: запись идёт по событиям сессий/проб, а не на каждый чих интерфейса.
  Future<void> _saveHistory() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('nodeHist',
          jsonEncode({for (final e in nodeHist.entries) e.key: e.value.toJson()}));
    } catch (e) {
      debugPrint('_saveHistory failed: $e');
    }
  }

  /// Фон-цикл автовыбора (таймер kAutoSelectTick, initState). Всё тяжёлое привязано к
  /// условиям: на Android пробуем только в форграунде (батарея), при поднятом туннеле приговоры
  /// не трогаем, статистика/сеть — с собственными троттлингами внутри.
  Future<void> _autoTick() async {
    if (!mounted || _locked) return;
    // Свежая статистика хаба (джиттер/стабильность/мёртвые узлы для скора). Внутри троттлинг
    // 5 минут — частых тиков не боится; сбой сети просто оставляет прежний отчёт.
    unawaited(_maybeRefreshNodeStats());
    // Смена сети Wi-Fi↔LTE: отпечаток раньше снимался ТОЛЬКО внутри ручного замера, и после
    // переезда на другую сеть приложение до получаса показывало чужие приговоры. Здесь дешёвый
    // whoami (6 с): сеть сменилась → приговоры со старой сами перестают быть свежими (stateOf
    // их отсеивает по net), а рабочий набор перепроверяем дозамером ниже.
    if (_foreground && conn == 0) {
      final net = await _networkId();
      if (!mounted) return;
      if (net.isNotEmpty && net != netId) {
        final hadVerdicts = netId.isNotEmpty && nodeVerdicts.isNotEmpty;
        rebuild(() => netId = net);
        unawaited(_saveVerdicts()); // сохраняем новый отпечаток рядом со старыми приговорами
        if (hadVerdicts && bestServer) _repickBest(); // на новой сети расклад может быть иным
      }
    }
    if (!mounted) return;
    if (conn == 0 && bestServer) {
      // Дозамер ТОЛЬКО просроченного подмножества и ТОЛЬКО в форграунде: фон-проба поднимает
      // временный движок на каждый узел — на мобильной сети это заметный расход батареи, а
      // свернутому приложению свежий пинг всё равно не нужен. Молчащие узлы переспрашиваем
      // с экспоненциальным бэкоффом (probeDue), узлы со свежим приговором не дёргаем вовсе.
      final canProbe = _foreground && !_pinging && subNodes.isNotEmpty;
      if (canProbe) {
        final now = DateTime.now();
        final stale = [
          for (final n in subNodes)
            if (n.server.isNotEmpty &&
                stateOf(n.tag) != NodeState.works &&
                probeDue(nodeHist[n.tag], now))
              n.tag,
        ];
        if (stale.isNotEmpty) unawaited(_pingServers(silent: true, onlyTags: stale.toSet()));
      }
      // Пересчёт лучшего по свежим данным (статистика хаба/история могли смениться без замера).
      if (mounted) rebuild(_repickBest);
    } else if (conn == 2 && bestServer) {
      _maybeAutoMigrate();
    }
  }

  /// Мягкая миграция деградировавшего туннеля (десктоп, hot-switch без разрыва). Правила —
  /// в shouldAutoMigrate: только превентивный фейловер с деградировавшего узла на разительно
  /// лучший, при низком трафике и с анти-маятником. Провал hotSwitch — остаёмся как были.
  Future<void> _maybeAutoMigrate() async {
    if (TunnelEngine.kind() != EngineKind.desktopXray || hotSwitching) return;
    final cur = server;
    if (cur.id.isEmpty) return;
    final best = serverForMode(mode);
    if (best.id.isEmpty || best.id == cur.id) return;
    final stat = _statFor(cur);
    final sessionSecs = _sessionStartedAt != null
        ? DateTime.now().difference(_sessionStartedAt!).inSeconds
        : 0;
    final sinceSwitch = _lastAutoMigrateAt != null
        ? DateTime.now().difference(_lastAutoMigrateAt!).inSeconds
        : 1 << 30;
    final yes = shouldAutoMigrate(
      bestOn: bestServer,
      desktop: true,
      curScore: _scoreOf(cur, mode),
      bestScore: _scoreOf(best, mode),
      curPingMs: pingOf(cur),
      curStatsDead: stat != null && !stat.ok,
      trafficKbps: down + up,
      sessionSecs: sessionSecs,
      sinceLastSwitchSecs: sinceSwitch,
    );
    if (!yes) return;
    final okSwitch = await TunnelEngine.instance.hotSwitch(subNodes, best.id);
    if (!mounted || !okSwitch) return;
    rebuild(() {
      server = best; // bestServer НЕ трогаем: это авто-фейловер, а не ручной выбор
      _lastAutoMigrateAt = DateTime.now();
    });
    _toast(appLang == 'en'
        ? 'Current node degraded — moved to ${tr(best.city)}'
        : 'Текущий узел деградировал — переключил на ${tr(best.city)}');
  }


  // ----- реальные действия -----
  void _toast(String m) {
    if (!mounted) return; // из catch/таймаут-веток может прийти после размонтирования — не падаем
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(children: [
          Container(width: 4, height: 30, decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 12),
          // Цвет текста — из текущей темы (C.text): иначе в светлой теме тёмный текст ложился на
          // захардкоженный тёмный фон и был нечитаем.
          // tr() прямо здесь: в тосты приходят и сообщения из движка/сети, которые бросаются
          // исключениями и потому не проходят через tr() на месте. Без перевода они оставались
          // русскими даже в английском интерфейсе. tr() возвращает исходную строку, если её нет
          // в словаре, — для остальных тостов ничего не меняется.
          Expanded(child: Text(tr(m), style: disp(14, w: FontWeight.w600, c: C.text))),
        ]),
        // Фон тоже тема-зависимый (C.bg2): белый в светлой, near-black в тёмной — читается в обеих.
        backgroundColor: C.bg2,
        behavior: SnackBarBehavior.floating,
        // фиксированная ширина вместо margin: на развёрнутом окне тост растягивался во весь экран;
        // width сам центрирует SnackBar (width и margin вместе задавать нельзя)
        width: math.min(420.0, MediaQuery.of(context).size.width - 32),
        elevation: 10,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14), side: BorderSide(color: C.accent.withValues(alpha: 0.45))),
        duration: const Duration(seconds: 3),
      ));
  }

  Future<void> _open(String url) async {
    try {
      final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok) _toast(tr('Не удалось открыть ссылку'));
    } catch (_) {
      _toast(tr('Не удалось открыть ссылку'));
    }
  }

  Future<void> _copy(String text, String label, {bool secret = false}) async {
    // ждём фактической записи в буфер, потом сообщаем «скопировано» — иначе тост мог опередить запись
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    // Секреты (vpn_key / «Код входа») чистим из системного буфера через 90с — иначе они лежат
    // там бессрочно (Windows Clipboard History, Universal Clipboard, менеджеры буфера). Стираем
    // только если там всё ещё НАШЕ значение (юзер мог скопировать что-то другое). Вставить в
    // роутер/клиент успевают за секунды. Реф-ссылка и прочее (secret:false) не трогаются.
    if (secret) {
      Future.delayed(const Duration(seconds: 90), () async {
        final d = await Clipboard.getData('text/plain');
        if (d?.text == text) await Clipboard.setData(const ClipboardData(text: ''));
      });
    }
    _toast(appLang == 'en' ? '$label · copied to clipboard' : '$label · скопировано в буфер');
  }

  // Хост берём ТЕМ ЖЕ парсером (outboundFromKey), что строит реальный outbound в singbox_config.dart —
  // иначе проверка доверенного хоста и фактический коннект расходятся:
  //   • vless://u@bitaps.app:443@evil.com → outboundFromKey отдаёт u.host = «evil.com» (userinfo до
  //     ПОСЛЕДНЕГО @), а не «bitaps.app» — юзеру не покажут доверенное имя при уходе трафика на злой хост.
  //   • vmess:// и ss:// в base64-форме: Uri.parse().host вернул бы мусорный base64-блоб (и ложное
  //     «это не сервер bitaps» для настоящего ключа); outboundFromKey декодирует тело и даёт реальный server.
  String? _hostOf(String key) {
    try {
      final h = outboundFromKey(key.trim())?['server'] as String?;
      if (h != null && h.isNotEmpty) return h;
    } catch (e) {
      // НЕ логируем сам ключ: FormatException.toString() включает исходную строку (vless://…) → утечка ключа в лог
      debugPrint('_hostOf error: ${e.runtimeType}');
    }
    return null;
  }

  // Доверенный хост = точный домен bitaps, а не любая строка с подстрокой 'bitaps'
  // (иначе bitaps.attacker.com / evil-bitaps.io прошли бы без предупреждения).
  // Делегирует к общей isTrustedBitapsHost (singbox_config.dart) — единый список доменов
  // и логика сравнения с гардом туннеля (_isTrustedTunnelHost), чтобы они не разъезжались.
  bool _isTrustedHost(String host) => isTrustedBitapsHost(host);

  Future<bool?> _confirmForeignHost(String host) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: C.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
        title: Text(tr('Не сервер bitaps'), style: disp(18, w: FontWeight.w700)),
        content: Text(
            appLang == 'en'
                ? '$host is not an official bitaps server. Import the key anyway?'
                : '$host — это не официальный сервер bitaps. Импортировать ключ всё равно?',
            style: mono(13, c: C.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Отмена'), style: mono(13, c: C.muted))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Импортировать'), style: mono(13, c: C.accent))),
        ],
      ),
    );
  }

  String get _netErr => tr('Нет связи с сервером — проверь интернет.');
  String _srvErr(int code) =>
      appLang == 'en' ? 'Server unavailable ($code). Try again later.' : 'Сервер недоступен ($code). Попробуй позже.';

  void _doLogout({bool silent = false}) {
    // сброс подключения (гасит поколение/таймеры/статус + возвращает кнопку в покой) — в контроллере,
    // чтобы отложенный коллбэк подключения не «переподключил» после выхода
    _conn.reset();
    setState(() {
      tgId = null;
      appToken = null;
      loginSecret = null;
      subPlan = null;
      subExpires = null;
      subName = null;
      subLimit = null;
      subActive = false;
      devices = [];
      devicesUnknown = false;
      // статистика аккаунта — тоже персональные данные: чистим при выходе
      statMemberSince = null;
      statPaidDays = null;
      statRefs = null;
      statTokens = null;
      subStreak = 0;
      subNextBonus = 0;
      subVip = false;
      keyStr = kDemoKey;
      // сбрасываем импортированный ключ/конфиг — иначе _applySub (гард importedHost==null)
      // не подхватит ключ следующего аккаунта после «тихого» логаута по истечению сессии
      importedHost = null;
      customCfg = null;
    });
    _save();
    _refreshTray(); // сбрасываем «дни/подписка» в меню трея после выхода
    if (!silent) _toast(tr('Вышли из аккаунта'));
  }

  void _logout() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: C.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
        title: Text(tr('Выйти?'), style: disp(18, w: FontWeight.w700)),
        content: Text(tr('Выйдешь из аккаунта на этом устройстве. Подключение отключится, персональные настройки сохранятся.'), style: mono(13, c: C.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Отмена'), style: mono(13, c: C.muted))),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              // полный teardown через _doLogout: сбрасывает keyStr=demo (закрывает утечку ключа
              // прошлого аккаунта), conn, spin, и _save() перезаписывает pref 'key' демо-ключом
              _doLogout();
              // явный выход дополнительно чистит импортированный ключ/хост и их prefs
              final p = await SharedPreferences.getInstance();
              await p.remove('cfg'); await p.remove('host');
              if (mounted) setState(() { customCfg = null; importedHost = null; });
            },
            child: Text(tr('Выйти'), style: mono(13, c: C.danger)),
          ),
        ],
      ),
    );
  }

  void _dialog(String title, String body) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: C.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
        title: Text(title, style: disp(18, w: FontWeight.w700)),
        // фикс. ширина: без неё AlertDialog берёт ширину по самой длинной строке (IntrinsicWidth) —
        // на развёрнутом окне однострочный текст растягивал бы диалог в полосу почти во весь экран
        content: SizedBox(width: 360, child: Text(body, style: mono(13, c: C.text))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Ок'), style: mono(13, c: C.accent)))],
      ),
    );
  }

  // Единая точка смены вкладки: setState(tab) + _syncAnimations(). Звать ВЕЗДЕ вместо голого
  // rebuild(()=>tab=…), иначе анимации (шестерёнка/кольца/starfield) крутятся вхолостую на вкладке
  // без них и жгут батарею (как было у «сменить» на Главной, минуя логику _tabItem).
  void _goTab(int i) {
    setState(() => tab = i);
    _syncAnimations();
    // Открытие «Серверов» подтягивает свежие узлы (не чаще раза в 5 минут — внутри): новые
    // ноды подписки обязаны появляться без перелогина. И статистику доступности — тоже
    // (тот же троттлинг внутри _maybeRefreshNodeStats).
    if (i == 1) { _maybeRefreshNodes(); _maybeRefreshNodeStats(); }
  }

  void _pickServer(Server s) {
    // Запрещаем смену при conn==1 (идёт подключение): конфиг коннекта уже собран со старым
    // сервером — иначе UI показал бы один сервер, а туннель поднимался бы на другой (рассинхрон).
    if (conn != 0) {
      // Горячая смена БЕЗ разрыва (десктоп, живой туннель): движок поднимается на новом узле
      // параллельно, системный прокси переписывается атомарно после verify — окна голого
      // трафика нет. Провал — остаёмся на прежнем сервере, туннель не дёргался.
      if (conn == 2 && TunnelEngine.kind() == EngineKind.desktopXray &&
          s.available && s.id != server.id && !hotSwitching) {
        _hotSwitch(s);
        return;
      }
      _toast(tr('Отключись, чтобы сменить сервер'));
      return;
    }
    if (!s.available) {
      _toast(appLang == 'en' ? '${tr(s.city)} — soon' : '${tr(s.city)} — скоро');
      return;
    }
    // Выбор конкретного сервера выключает режим «лучший сервер» (ползунок на Главной) —
    // иначе toggle() молча заменил бы только что выбранный сервер на «оптимальный».
    setState(() { server = s; bestServer = false; });
    _save();
    _toast(appLang == 'en' ? 'Server: ${tr(s.city)}' : 'Сервер: ${tr(s.city)}');
  }

  /// Горячая смена сервера на живом подключении (десктоп). Прокси не дёргается до подтверждения
  /// нового узла — см. TunnelEngine.hotSwitch; неудача → остаёмся на прежнем (он не прерывался).
  Future<void> _hotSwitch(Server s) async {
    if (hotSwitching) return;
    final prev = server;
    rebuild(() { hotSwitching = true; hotSwitchTarget = s.city; });
    final ok = await TunnelEngine.instance.hotSwitch(subNodes, s.id);
    if (!mounted) return;
    rebuild(() {
      hotSwitching = false; hotSwitchTarget = '';
      if (ok) { server = s; bestServer = false; }
    });
    if (ok) {
      _save(); // ручной выбор персистим, как при обычной смене (serverId)
      _toast(appLang == 'en' ? 'Switched to ${tr(s.city)}' : 'Переключено: ${tr(s.city)}');
    } else {
      _toast(appLang == 'en'
          ? "Couldn't switch to ${tr(s.city)} — stayed on ${tr(prev.city)}"
          : 'Не удалось переключиться на ${tr(s.city)} — остался на ${tr(prev.city)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    // _syncAnimations больше НЕ регистрируем пост-фреймом на каждый build (плодило аллокации на
    // частых setState). Вместо этого зовём его событийно у мутаторов, влияющих на видимость анимаций:
    // смена вкладки (_tabItem), темы (_themeChip/didChangePlatformBrightness), стиля кнопки (_styleChip),
    // подключения (слушатель _conn), блокировки (lifecycle/_tryUnlock/_forgotPin) и первично в initState.
    // Статус-бар/системные оверлеи под актуальную тему: в светлой — тёмные иконки, в тёмной — светлые.
    final overlay = (C.light ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light).copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: C.bg,
      systemNavigationBarIconBrightness: C.light ? Brightness.dark : Brightness.light,
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(value: overlay, child: _buildBody());
  }

  Widget _buildBody() {
    if (_locked) return _lockScreen();
    if (_showOnboarding) return _onboarding(); // знакомство поверх всего (после PIN-замка)
    // Строим ТОЛЬКО активный экран: раньше каждый setState (включая посекундный тик таймера
    // подключения) собирал все четыре — вчетверо дороже без какой-либо пользы.
    final screen = switch (tab) { 0 => _home(), 1 => _servers(), 2 => _account(), _ => _settings() };
    // Контентная колонка: центр, максимум 560px (мобильная раскладка не меняется).
    final content = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          child: KeyedSubtree(key: ValueKey(tab), child: screen))));
    // Десктоп-каркас: широкое окно (>720) → слева узкий рейл навигации, справа активный экран;
    // узкое — как раньше (нижний таб-бар). Экраны — те же extension'ы, меняется только каркас.
    return LayoutBuilder(builder: (context, cons) {
      final wide = cons.maxWidth > 720;
      return Scaffold(
        backgroundColor: C.bg,
        body: Stack(children: [
          Positioned.fill(child: ColoredBox(color: C.bg)),
          // RepaintBoundary: starfield анимирует 60 fps — без собственного слоя он инвалидировал
          // бы отрисовку всего экрана каждый кадр; с ним композитор переиспользует остальные слои.
          if (!C.light) Positioned.fill(child: RepaintBoundary(child: AnimatedBuilder(
            animation: _twinkle,
            builder: (_, __) => CustomPaint(painter: StarPainter(_twinkle.value * 2 * math.pi)),
          ))),
          Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
            gradient: RadialGradient(center: const Alignment(0, -0.95), radius: 0.95,
              colors: [C.accent.withValues(alpha: C.light ? 0.16 : 0.17), C.accent.withValues(alpha: 0)])))),
          // синий угловой градиент — только обычная тёмная тема (в Фосфоре синий спорит с зелёным)
          if (!C.light && !C.phosphor) const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
            gradient: RadialGradient(center: Alignment(1.0, -0.9), radius: 0.8,
              colors: [Color(0x1A2D8BFF), Color(0x002D8BFF)])))),
          // Фоны (Positioned.fill) — во всю ширину; контент — колонкой 560px по центру,
          // на широком десктопе слева добавляется рейл.
          SafeArea(bottom: false, child: wide
            ? Row(children: [_navRail(), Expanded(child: content)])
            : content),
          // CRT-сканлайны — поверх контента, только в теме «Фосфор». IgnorePointer: не перехватывает тапы.
          if (C.phosphor) const Positioned.fill(child: IgnorePointer(
            child: RepaintBoundary(child: CustomPaint(painter: ScanlinePainter())))),
        ]),
        bottomNavigationBar: wide ? null : _bottomBar(),
      );
    });
  }

  // Пункты навигации — общие для нижнего бара и десктоп-рейла.
  List<(String, IconData)> get _navItems => [
    (tr('Главная'), Icons.power_settings_new),
    (tr('Серверы'), Icons.public),
    (tr('Кабинет'), Icons.person_outline),
    (tr('Настройки'), Icons.settings_outlined),
  ];

  // ---------------- DESKTOP NAV RAIL ----------------
  // Узкий стеклянный рейл слева (ширина >720): мини-лого + те же 4 пункта вертикально.
  Widget _navRail() {
    final items = _navItems;
    return ClipRect(child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      child: Container(
        width: 96,
        decoration: BoxDecoration(
          color: C.bg2.withValues(alpha: 0.7),
          border: Border(right: BorderSide(color: C.line))),
        child: Column(children: [
          const SizedBox(height: 18),
          // мини-лого — как в шапке Главной (₿-квадрат с градиентом)
          Container(width: 34, height: 34, alignment: Alignment.center,
            decoration: BoxDecoration(gradient: accentGrad, borderRadius: BorderRadius.circular(10),
              boxShadow: [BoxShadow(color: C.accent.withValues(alpha: 0.5), blurRadius: 12)]),
            child: Text('₿', style: disp(19, w: FontWeight.w900, c: C.bg))),
          const SizedBox(height: 20),
          for (int i = 0; i < items.length; i++) _railItem(items[i].$1, items[i].$2, i),
          const Spacer(),
          // статус-пилюля внизу рейла — то же честное состояние, что и на Главной;
          // FittedBox ужимает «не защищено» в 96px рейла (иначе overflow)
          Padding(padding: const EdgeInsets.only(bottom: 16, left: 6, right: 6),
            child: FittedBox(fit: BoxFit.scaleDown, child: _shieldPill(conn == 2))),
        ]),
      ),
    ));
  }

  Widget _railItem(String label, IconData ic, int i) {
    final sel = tab == i;
    return Semantics(
      button: true,
      selected: sel,
      label: label,
      container: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _goTab(i),
        child: ExcludeSemantics(
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: sel ? C.accent.withValues(alpha: 0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              // рамка задана всегда (прозрачная у невыбранных) — размер пункта не прыгает
              border: Border.all(color: sel ? C.accent.withValues(alpha: 0.45) : Colors.transparent)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(ic, size: 22, color: sel ? C.accent : C.muted),
              const SizedBox(height: 4),
              Text(label, style: mono(10.5, c: sel ? C.accent : C.muted, w: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------------- BOTTOM NAV ----------------
  Widget _bottomBar() {
    final items = _navItems;
    return ClipRect(child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      child: Container(
        decoration: BoxDecoration(color: C.bg2.withValues(alpha: 0.7), border: Border(top: BorderSide(color: C.line))),
        // Стеклянная подложка бара — во всю ширину, но сами вкладки держим в той же 560px-колонке,
        // что и контент (иначе на широком окне 4 таба разъезжались бы по краям на сотни px).
        // heightFactor: 1 обязателен. Без него Center забирает ВСЮ доступную высоту, а Scaffold
        // отдаёт нижнему бару столько, сколько тот попросил, — телу остаётся ноль. Внешне это
        // выглядело так: иконки вкладок висят посреди экрана, а весь контент исчез. На десктопе
        // не проявлялось: широкое окно использует боковой рейл, а не нижний бар.
        child: SafeArea(top: false, child: Center(heightFactor: 1, child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            // Expanded на каждую вкладку: при spaceAround с естественной шириной четыре подписи
            // («Настройки» — длинная) не влезали в 360px и обрезались. Теперь вкладки делят
            // ширину поровну, а подпись внутри при нехватке места ужимается.
            child: Row(children: [for (int i = 0; i < 4; i++) Expanded(child: _tabItem(items[i].$1, items[i].$2, i))]),
          ),
        ))),
      ),
    ));
  }

  Widget _tabItem(String label, IconData ic, int i) {
    final sel = tab == i;
    // Semantics для скринридера: элемент навигации как кнопка-вкладка с меткой и признаком выбора.
    // ExcludeSemantics на содержимом — чтобы иконка+текст не дублировали метку.
    return Semantics(
      button: true,
      selected: sel,
      label: label,
      container: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _goTab(i),
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(ic, size: 22, color: sel ? C.accent : C.muted),
              const SizedBox(height: 4),
              // подпись вкладки ужимается, а не обрезается: «Настройки»/«Settings» длиннее ячейки
              FittedBox(fit: BoxFit.scaleDown, child:
                Text(label, maxLines: 1, style: mono(10.5, c: sel ? C.accent : C.muted, w: FontWeight.w600))),
            ]),
          ),
        ),
      ),
    );
  }
}
