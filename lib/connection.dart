part of 'main.dart';

/// Что предложить сделать с неудачной попыткой подключения — кнопка под причиной на Главной.
/// Причина без действия оставляет человека там же, где и молчание: «не работает, и что теперь».
enum ConnFix {
  /// Действия нет — достаточно объяснения (например, повторить попытку).
  none,
  /// Обновить подписку: истекла, занят лимит устройств, узлов не пришло.
  refreshSub,
  /// Отдать ключ стороннему клиенту Happ — он умеет то, что не умеет наш движок.
  happ,
  /// Сами не починим — довести человека до поддержки.
  support,
  /// Узел не пропускает трафик: выбрать другой сервер (кнопка ведёт на список).
  pickOther,
}

// ============================ CONNECTION CONTROLLER ============================
// Жизненный цикл VPN-подключения вынесен из ShellState (god-object): здесь живут состояние
// туннеля (conn/secs/скорость/поколение/таймеры/счётчик трафика) и вся логика connect/disconnect,
// обрыва и демо-сессии. Контроллер НЕ знает про виджеты — зависимости от UI прокинуты колбэками:
//   keyOf/serverOf   — актуальные ключ и выбранный сервер из ShellState
//   dropAlertOn      — тумблер «Обрыв соединения»
//   trafWarnOn       — тумблер «Лимит трафика»
//   killSwitchOn     — тумблер «Килл-свитч»: при НЕОЖИДАННОМ обрыве держим fail-closed
//   reconnectOn      — тумблер «Автопереподключение»: после НЕОЖИДАННОГО обрыва сами
//                      переподключаемся с нарастающей паузой (см. reconnectDelay)
//   demoOn           — тумблер «Демо-режим» (Настройки): разрешена ли демо-сессия без движка
//   onToast          — показать тост (реализует ShellState)
//   onPersist        — сохранить состояние (_save; нужен для счётчика сессий)
//   onSpin(fast)     — крутить кнопку-шестерёнку: быстро во время коннекта, медленно в покое
// Обновления UI идут через ChangeNotifier: ShellState слушает и делает setState.
class ConnectionController extends ChangeNotifier {
  ConnectionController({
    required this.keyOf,
    required this.hwidOf,
    required this.serverOf,
    required this.onNodes,
    required this.bestServerOn,
    required this.nextServerOf,
    required this.dropAlertOn,
    required this.trafWarnOn,
    required this.killSwitchOn,
    required this.reconnectOn,
    required this.demoOn,
    required this.onNodeDead,
    required this.onToast,
    required this.onPersist,
    required this.onSpin,
  });

  final String Function() keyOf;
  /// Идентификатор устройства для заголовка x-hwid при загрузке подписки (лимит устройств).
  final String Function() hwidOf;
  final Server Function() serverOf;
  /// Свежие узлы подписки — чтобы список серверов в интерфейсе не расходился с тем,
  /// к чему реально подключаемся. [cacheAt] != null — список поднят из персистентного
  /// кэша (выдача недоступна — сеть в режиме «белых списков»), UI покажет пометку с датой.
  final void Function(List<SubNode>, {DateTime? cacheAt}) onNodes;
  /// Режим «лучший сервер» включён? Тогда узел, не пропустивший трафик, не тупик:
  /// тем же нажатием перебираем следующих кандидатов (см. цикл в toggle()).
  final bool Function() bestServerOn;
  /// Следующий кандидат автоперебора — та же логика выбора, что дала стартовый сервер,
  /// но уже с учётом свежего приговора только что помеченному узлу (см. onNodeDead).
  final Server Function() nextServerOf;
  final bool Function() dropAlertOn;
  final bool Function() trafWarnOn;
  /// Тумблер «Килл-свитч» (Настройки): при НЕОЖИДАННОМ обрыве VPN трафик блокируется
  /// (fail-closed), а не идёт напрямую. По умолчанию ВЫКЛ.
  final bool Function() killSwitchOn;
  /// Тумблер «Автопереподключение» (Настройки): после НЕОЖИДАННОГО обрыва переподключаемся
  /// сами, с нарастающей паузой и бессрочно. По умолчанию ВКЛ — тумблер и есть согласие
  /// человека; выключил — после обрыва остаёмся отключёнными, как раньше.
  final bool Function() reconnectOn;
  /// Разрешена ли демо-сессия там, где движка нет. По умолчанию ВЫКЛЮЧЕНА: молчаливое демо
  /// после оплаты выглядело как рабочий VPN и человек не понимал, почему ничего не открывается.
  final bool Function() demoOn;
  /// Узел не пропустил трафик — записать приговор, чтобы он не считался доступным.
  final void Function(String nodeTag) onNodeDead;
  final void Function(String msg) onToast;
  final Future<void> Function() onPersist;
  final void Function(bool fast) onSpin;

  int conn = 0; // 0 off · 1 connecting · 2 on
  /// Почему последняя попытка не удалась (null — причин нет). Тост живёт три секунды, а человек
  /// к этому моменту смотрит на «Отключено · нажми на кнопку» и читает это как «нажатие не
  /// сработало». Причина обязана оставаться на экране до следующей попытки — см. карточку на Главной.
  String? failMsg;
  ConnFix failFix = ConnFix.none;
  /// Килл-свитч сработал: VPN отвалился НЕОЖИДАННО (не по кнопке) и системный прокси нарочно
  /// не снят — трафик заблокирован (fail-closed). Живёт до кнопки «Снять блокировку» или новой
  /// попытки подключения. Нарочно НЕ персистится: при старте приложения протухший прокси всё
  /// равно снимает cleanupStale (main.dart) — после перезапуска блокировки фактически нет,
  /// и UI не должен её выдумывать.
  bool blocked = false;
  int secs = 0;
  int down = 0, up = 0;
  int sessions = 0;
  int _gen = 0; // поколение подключения: гасит «поздние» коллбэки отменённых/сменённых попыток
  Timer? _timer;
  StreamSubscription<EngineEvent>? _tunEvents;
  // ── авто-реконнект: серия попыток после НЕОЖИДАННОГО обрыва ──
  Timer? _reconnectTimer; // ждём паузу перед очередной попыткой
  /// Номер текущей попытки автопереподключения (0 — серии нет). Показываем его на Главной
  /// («переподключение, попытка N»): молчащая пауза между попытками выглядела бы как
  /// «отключено и ничего не происходит».
  int reconnectAttempt = 0;
  /// Идёт ли серия автопереподключения: ждём таймер (ожидание паузы). Во время самой попытки
  /// (conn == 1) признак серии — reconnectAttempt > 0.
  bool get reconnecting => _reconnectTimer != null;
  // ── watchdog: фоновая проверка, что ПОДНЯТЫЙ туннель жив ──
  // Событие обрыва приходит не всегда: сессию может рвать фильтрация молча (иконка VPN есть,
  // интернета нет, приложение пишет «Подключено»). Пока conn == 2, раз в 30с тянем лёгкий
  // gen204 сквозь туннель; три подряд неудачи — туннель мёртв, идём тем же путём, что и
  // обрыв (_dropped): fail-state + серия автореконнекта по тумблеру.
  Timer? _watchdog;
  int _watchdogFails = 0;
  bool _watchdogBusy = false; // verify до ~12с при тике 30с — гвард от наложения
  static const Duration kWatchdogInterval = Duration(seconds: 30);
  /// Подряд неудачных проверок до объявления туннеля мёртвым (каждая — уже два gen204-раунда
  /// внутри verifyConnected, то есть ~90с подтверждённой тишины — ложных разрывов не будет).
  static const int kWatchdogMaxFails = 3;
  // ── автоперебор кандидатов (режим «лучший сервер»): кто сейчас на пробе ──
  /// Сколько кандидатов перебираем максимум за одно нажатие «Подключиться».
  static const int kMaxTryAttempts = 5;
  /// Какой по счёту кандидат сейчас подключается (0 — перебора нет: ручной выбор или покой)
  /// и его название — прогресс «пробуем {сервер}… (N/5)» на Главной.
  int tryAttempt = 0;
  String tryServer = '';
  double _sessMB = 0;       // накопленный расход за текущую сессию (для «Лимит трафика»)
  bool _trafWarned = false; // предупреждение о большом расходе уже показано в этой сессии
  bool _disposed = false;
  final math.Random _rnd = math.Random();

  String get hms {
    if (secs >= 86400) {
      final d = secs ~/ 86400;
      final h = (secs % 86400) ~/ 3600;
      return appLang == 'en' ? '${d}d ${h}h' : '$dд $hч';
    }
    final h = (secs ~/ 3600).toString().padLeft(2, '0');
    final m = ((secs % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Future<void> toggle() async {
    // Ручная команда (кнопка/трей/хоткей) во время ожидания очередной попытки отменяет серию
    // автопереподключения: человек взял управление на себя. Вызов ИЗ таймера серии сюда не
    // задевает: к этому моменту _reconnectTimer уже снят (см. _scheduleReconnect).
    if (_reconnectTimer != null) _cancelReconnect();
    if (conn == 1) {
      // отмена во время «Подключение…»: инвалидируем поколение → awaited/отложенный коллбэк отвалится
      _gen++;
      _cancelReconnect(); // отменяет и попытку ИЗ серии автопереподключения — гасим её всю
      _resetTry(); // отмена и автоперебора: цикл кандидатов умрёт по gen != _gen
      // Отмена попытки, поднятой ИЗ блокировки: прокси держим (fail-closed), гасим только
      // движок — иначе blocked-карточка осталась бы при уже снятом прокси (ложь и голый трафик).
      if (kRealTunnel) { await _stopEngine(); gEngineReal = false; }
      _stopWatch();
      onSpin(false);
      conn = 0;
      notifyListeners();
      return;
    }
    if (conn == 0) {
      // Новая попытка ИЗ состояния блокировки прокси НЕ снимает и blocked НЕ сбрасывает заранее:
      // старый прокси указывает в мёртвый порт (трафик заблокирован), а разрыв «снял → поднял»
      // оставлял бы секунды голого трафика напрямую. Новый движок атомарно перепишет порты в
      // SystemProxy.enable (keepProxy в _connectDesktop), blocked снимается ТОЛЬКО в _startSession,
      // а при неудаче возвращается в _fail — блокировка держится всю попытку.
      final gen = ++_gen; // это конкретное подключение; отмена/реконнект сменят _gen
      conn = 1;
      failMsg = null; failFix = ConnFix.none; // новая попытка — старую причину с экрана убираем
      notifyListeners();
      onSpin(true);

      // Боевой режим возможен, только если на этой платформе реально есть движок:
      // на десктопе — лежащий рядом xray (он умеет и узлы «белого списка»), на мобильных —
      // нативная сторона. Нет движка → остаёмся в честном демо-режиме, как раньше.
      final engineKind = TunnelEngine.kind();
      if (kRealTunnel && engineKind != EngineKind.none) {
        // БОЕВОЙ режим: поднимаем НАСТОЯЩИЙ туннель.
        // trim + lowercase-схема как в парсере (singboxConfigJson тоже триммит/нормализует): иначе
        // ключ с ведущим пробелом или «VLESS://» гард отверг бы, хотя парсер его разбирает.
        final key = keyOf().trim();
        // Демо-заглушка — НЕ ключ: синтаксически она валидна (vless://…), но pbk у неё
        // ненастоящий, и без этого гарда коннект умирал бы невнятной ошибкой движка.
        if (key == kDemoKey) { _fail(gen, tr('Сначала войди или импортируй ключ'), fix: ConnFix.refreshSub); return; }
        // Подписка (https://…/u/<token>) — не одиночный ключ: её надо СКАЧАТЬ и собрать конфиг
        // из всех узлов сразу. Одиночные share-link'и идут прежним путём без изменений.
        final isSub = isSubscriptionUrl(key);
        // пускаем все схемы, что умеет singbox_config (не только vless://) — иначе валидный
        // trojan/vmess/ss/hysteria2-ключ ложно отвергался бы «Нужен рабочий VPN-ключ».
        if (!isSub && !kSupportedKeySchemes.any((s) => key.toLowerCase().startsWith(s))) { _fail(gen, tr('Нужен рабочий VPN-ключ'), fix: ConnFix.refreshSub); return; }
        List<SubNode> nodes = const [];
        if (isSub) {
          // Кэшированная выдача: под «белыми списками» origin.bit-core.online мёртв — после
          // сбоя сети молча поднимаем список из кэша (TTL 7 дней, см. fetchSubscriptionCached).
          final sub = await fetchSubscriptionCached(key, hwid: hwidOf(), deviceOs: Platform.operatingSystem, store: subCacheStore);
          if (_disposed || gen != _gen) return; // отменили, пока грузилась подписка
          // Сервис отвечает уведомлением вместо узлов: подписка истекла / исчерпан лимит устройств.
          // Показываем его текст как есть — он уже написан для пользователя и локализован сервисом.
          if (sub.notice != null && !sub.ok) { _fail(gen, sub.notice!, fix: ConnFix.refreshSub); return; }
          if (sub.error != null) { _fail(gen, sub.error!, fix: ConnFix.refreshSub); return; }
          onNodes(sub.nodes, cacheAt: sub.cachedAt);
          nodes = TunnelEngine.usableNodes(sub.nodes);
          if (nodes.isEmpty) {
            // Узлы пришли, но наш движок их не понимает → Happ понимает: это не тупик, а обход.
            // Если же записи были, но ВСЕ отброшены гейтом/капом (skipped > 0), говорим честно:
            // иначе человек видел бы «нет серверов» при живой, но отрезанной выдаче.
            _fail(gen,
                sub.nodes.isNotEmpty
                    ? tr('Узлы подписки не поддерживаются этой сборкой')
                    : sub.skipped > 0
                        ? tr('Узлы подписки отклонены: чужие адреса')
                        : tr('В подписке нет доступных серверов'),
                fix: sub.nodes.isNotEmpty ? ConnFix.happ : ConnFix.refreshSub);
            return;
          }
        } else {
          // Одиночный ключ (импортированный вручную) — заворачиваем в такой же узел подписки,
          // чтобы дальше был один путь подключения для обоих случаев.
          final one = subNodeFromKey(key);
          if (one == null) {
            _fail(gen, appLang == 'en' ? 'Key is corrupted' : 'Ключ повреждён', fix: ConnFix.refreshSub);
            return;
          }
          nodes = TunnelEngine.usableNodes([one]);
          if (nodes.isEmpty) { _fail(gen, tr('Этот ключ не поддерживается этой сборкой'), fix: ConnFix.happ); return; }
        }
        // Разрешение на VPN спрашиваем ДО таймаута: системный диалог показывает система, читает
        // его человек, и его время не имеет отношения к тому, «завис ли движок». Раньше эти
        // секунды входили в те же 40 — и неспешный пользователь получал «таймаут» одновременно
        // с поднявшимся туннелем: ключ в шторке горит, а приложение говорит «Отключено».
        if (!await TunnelEngine.instance.ensurePermission()) {
          if (_disposed || gen != _gen) return;
          _fail(gen, appLang == 'en'
              ? 'VPN permission is required to connect'
              : 'Нужно разрешить приложению создавать VPN-подключение', fix: ConnFix.none);
          return;
        }
        if (_disposed || gen != _gen) return; // отменили, пока человек читал диалог
        // Автоперебор до первого ЖИВОГО трафика (только режим «лучший сервер»): узел, не
        // пропустивший трафик, помечается приговором, и тем же нажатием пробуем следующего
        // кандидата — всего до kMaxTryAttempts. Раньше человек жмал «подключиться» по пять
        // раз вручную. Ручной выбор — одна попытка, как раньше (roam == false).
        // Реконнект сюда не лезет: он начинается после ОБРЫВА УСТАНОВЛЕННОГО соединения,
        // а перебор работает до первого успешного коннекта и серии не создаёт.
        // Режим «ограниченная сеть» (белые списки): быстрый пре-флайт (≤2 с, кэш ~60 с) —
        // прямые ноды мертвы, а CDN-рельсы живы → restricted. Тогда кандидатов перебираем
        // РЕЛЬСАМИ ВПЕРЁД (cdnFirst в compareServers читает TunnelEngine.lastProfile), а
        // ручному выбору прямой ноды разрешён один автоподхват рельсы — владелец прямо
        // просил: «гони всё при подключении через БС-ноды, чтобы не зависало».
        final restricted = nodes.length > 1 &&
            await TunnelEngine.instance.preflight(nodes) == NetProfile.restricted;
        if (_disposed || gen != _gen) return; // отменили, пока шёл пре-флайт
        final roam = bestServerOn();
        var candidate = serverOf();
        // Стартовый кандидат выбирался ДО пре-флайта (ShellState.toggle → serverForMode) и
        // мог оказаться прямой нодой — в restricted пересчитываем сразу: первая же попытка
        // должна идти на рельсу, а не тратить ~15 с на заведомо мёртвую прямую.
        if (restricted && roam) {
          final re = nextServerOf();
          if (re.id.isNotEmpty) candidate = re;
        }
        // restricted + ручной выбор прямой ноды: она мимо → подхватили рельсу (тост ниже).
        var rescuedDirect = false;
        for (var attempt = 1; ; attempt++) {
          // прогресс на Главной: «пробуем {сервер}… (N/5)» — иначе минуты перебора выглядели
          // бы зависшим «Подключение…».
          if (roam) { tryAttempt = attempt; tryServer = candidate.city; notifyListeners(); }
          try {
            // таймаут: если движок завис и не вернул ни успех, ни ошибку — не залипаем
            // навсегда в «Подключение…», а честно откатываемся в «выключено» с тостом.
            // Выбор сервера уважаем: подключаемся ровно к кандидату, а не к «лучшему».
            await TunnelEngine.instance
                .connect(nodes,
                         onlyTag: candidate.id.isNotEmpty && nodes.any((n) => n.tag == candidate.id) ? candidate.id : null,
                         server: candidate.city,
                         // из блокировки — прокси держим: enable() перепишет порты атомарно
                         keepProxy: blocked)
                .timeout(const Duration(seconds: 40));
          } on TunnelUnavailable catch (e) {
            // Нет разрешения на VPN-подключение: чинится повторной попыткой и «разрешить» в системе.
            _resetTry(); _fail(gen, '$e', fix: ConnFix.none);
            return;
          } on EngineUnavailable catch (e) {
            // Проблема самого движка (нет бинаря, занят порт) — Happ поднимет тот же ключ мимо него.
            // К узлу это отношения не имеет — перебирать кандидатов бессмысленно.
            _resetTry(); _fail(gen, '$e', fix: ConnFix.happ);
            return;
          } on TimeoutException {
            // Движок мог подняться уже ПОСЛЕ таймаута — тогда останется «осиротевший» туннель:
            // ключ в шторке горит, а интерфейс показывает «Отключено». Гасим дважды с паузой:
            // первый вызов ловит уже поднятый туннель, второй — тот, что встал следом.
            // При живой блокировке гасим БЕЗ снятия прокси (_stopEngine → failClosed).
            await _stopEngine().catchError((_) {});
            // Отложенный добив СТРОГО привязан к поколению: за эти 3 с человек мог начать
            // НОВУЮ попытку — без проверки gen/conn он убивал бы свежий движок (вплоть до
            // «Подключено» при мёртвом туннеле без единого события; багхант, HIGH).
            Future<void>.delayed(const Duration(seconds: 3), () {
              if (_disposed || gen != _gen || conn != 0) return;
              _stopEngine().catchError((_) {});
            });
            _resetTry(); _fail(gen, appLang == 'en' ? 'Connection timed out' : 'Подключение не удалось — таймаут', fix: ConnFix.none);
            return;
          } catch (e) {
            _resetTry(); _fail(gen, appLang == 'en' ? 'Failed to connect: $e' : 'Не удалось подключиться: $e');
            return;
          }
          if (_disposed || gen != _gen) { await _stopEngine(); return; } // отменили во время старта
          // «Подключено» и «работает» — разные вещи. Движок поднимает туннель и рапортует об успехе,
          // а сессию сквозь фильтрацию может рвать: у человека горит ключ в шторке и не грузится
          // ничего. Именно так сейчас ведут себя ПРЯМЫЕ узлы при глушении интернета, тогда как узлы
          // через CDN работают. Поэтому сразу после старта тянем маленький ответ СКВОЗЬ туннель —
          // это и есть критерий успеха кандидата (не TCP-пинг до его адреса).
          final passes = await TunnelEngine.instance.verifyConnected();
          if (_disposed || gen != _gen) { await _stopEngine(); return; }
          if (passes) break; // трафик пошёл — кандидат найден, выходим в сессию
          // Узел не пропускает трафик — держать на нём человека нельзя, это и есть то самое
          // «подключено, но интернета нет». Гасим (при живой блокировке — без снятия прокси),
          // помечаем приговором (не будет ни выбран «лучшим», ни показан доступным) и либо
          // пробуем следующего, либо честно останавливаемся.
          await _stopEngine().catchError((_) {});
          onNodeDead(candidate.id);
          Server? next;
          if (roamContinues(roam, attempt)) {
            next = nextServerOf(); // пересчёт с учётом свежего приговора
            // кандидаты кончились (все помечены мёртвыми на этой сети) — считаем как «все мимо»
            if (next.id.isEmpty || next.id == candidate.id) next = null;
          }
          // Restricted + ручной выбор ПРЯМОЙ ноды: она не пропустила трафик (ожидаемо в этой
          // сети) → ОДИН автоподхват первой живой рельсы вместо немедленного «выбери другой».
          if (next == null && roamRescue(roam, restricted, attempt, candidate)) {
            final rescue = nextServerOf(); // в restricted сортировка cdnFirst — первая живая рельса
            if (rescue.id.isNotEmpty && rescue.id != candidate.id) {
              next = rescue;
              rescuedDirect = true;
            }
          }
          if (next == null) {
            _resetTry();
            _fail(gen,
                roam ? tr('Ни один сервер не ответил — проверь интернет')
                     : tr('Через этот сервер сейчас не идёт трафик — выбери другой или включи «лучший сервер»'),
                fix: roam ? ConnFix.support : ConnFix.pickOther);
            return;
          }
          candidate = next;
          if (_disposed || gen != _gen) return; // отменили на стыке кандидатов
        }
        _resetTry();
        gEngineReal = true;
        _startSession(down: 0, up: 0);
        // Restricted-подхват: человек выбирал прямую ноду, а подключили его через рельсу —
        // молчать нельзя, иначе он не поймёт, почему сервер на экране не тот.
        if (rescuedDirect) {
          onToast(tr('Прямая нода недоступна в этой сети — подключил через 🛡️'));
        }
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (_disposed) return;
          secs++; _accTraffic(); notifyListeners();
        });
        // РЕАЛЬНАЯ статистика/статус из движка — никаких выдуманных чисел
        _tunEvents = TunnelEngine.instance.events.listen((e) {
          if (_disposed || gen != _gen) return;
          if (e.state == 'error' || e.state == 'disconnected') { _dropped(gen, why: e.message); return; }
          down = e.downKbps;
          up = e.upKbps;
          notifyListeners();
        // ошибка самого канала (смерть процесса движка вместе с EventChannel) не приходит событием
        // state=='error' — ловим её отдельно, иначе UI навсегда завис бы в «Подключено».
        }, onError: (_) { _dropped(gen); });
        return;
      }

      // Движка на этой платформе нет. Раньше отсюда МОЛЧА стартовала демо-сессия: человек видел
      // бегущий таймер, скорости и «Демо-режим» — экран выглядел рабочим, а трафик шёл мимо
      // туннеля. Оплативший при этом не понимал, почему ничего не открылось. Говорим прямо и
      // даём рабочий обход (Happ умеет наш ключ); демо остаётся, но только по явной просьбе
      // из Настроек — «посмотреть интерфейс», а не «подключиться».
      if (!demoOn()) {
        _fail(gen, tr('На этой системе туннель ещё не поддержан'), fix: ConnFix.happ);
        return;
      }

      // ДЕМО-режим (тумблер в Настройках): туннель НЕ поднимается — показываем демо-сессию
      // с явной пометкой «демо» в UI (см. home.dart). Цифры условны, это НЕ реальная защита.
      Future.delayed(const Duration(milliseconds: 1700), () {
        if (_disposed || gen != _gen) return; // «поздний» коллбэк отменённой попытки — игнор
        _startSession(down: 84, up: 13);
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (_disposed) return;
          secs++; down = 60 + _rnd.nextInt(70); up = 8 + _rnd.nextInt(20); _accTraffic(); notifyListeners();
        });
      });
    } else {
      _gen++; // отключение инвалидирует любое незавершённое поколение
      _cancelReconnect(); // ручное отключение — серия автопереподключения больше не нужна
      if (kRealTunnel) { await TunnelEngine.instance.disconnect(); gEngineReal = false; }
      _stopWatch();
      onSpin(false);
      conn = 0; secs = 0;
      notifyListeners();
    }
  }

  // старт сессии: обнуляем счётчики трафика/времени и поднимаем статус в «Подключено»
  void _startSession({required int down, required int up}) {
    _cancelReconnect(); // успешное подключение сбрасывает серию автопереподключения (backoff)
    conn = 2; secs = 0; this.down = down; this.up = up; sessions++;
    failMsg = null; failFix = ConnFix.none; // получилось — причина прошлой неудачи неактуальна
    blocked = false; // подключились — блокировки килл-свитча больше нет
    _sessMB = 0; _trafWarned = false;
    _startWatchdog(); // боевой режим: фоновая проверка «туннель правда жив» (см. выше)
    notifyListeners();
    onPersist();
  }

  // ── watchdog ──

  /// Подряд неудачных проверок, при которых живущий «Подключено» туннель объявляется
  /// мёртвым. Чистая функция — покрыта watchdog_test.
  static bool watchdogDrops(int consecutiveFails) => consecutiveFails >= kWatchdogMaxFails;

  void _startWatchdog() {
    _stopWatchdog();
    if (!gEngineReal) return; // демо-сессия: проверять нечего, verify гонять по воздуху не будем
    _watchdog = Timer.periodic(kWatchdogInterval, (_) => _watchdogTick());
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
    _watchdogFails = 0;
    _watchdogBusy = false;
  }

  Future<void> _watchdogTick() async {
    if (_disposed || conn != 2 || _watchdogBusy) return;
    _watchdogBusy = true;
    final gen = _gen;
    try {
      final ok = await TunnelEngine.instance.verifyConnected();
      if (_disposed || gen != _gen || conn != 2) return; // за проверку всё сменилось
      if (ok) {
        _watchdogFails = 0;
        return;
      }
      _watchdogFails++;
      if (!watchdogDrops(_watchdogFails)) return; // единичный сбой сети — не разрыв
      // Туннель мёртв, хотя события от движка не было. Тот же путь, что и обрыв: честный
      // fail-state + серия автореконнекта (тумблер уважаем) — килл-свитч здесь ни при чём.
      _dropped(gen, why: tr('Соединение потеряно'));
    } finally {
      _watchdogBusy = false;
    }
  }

  // сброс наблюдателей туннеля (таймер секунд + поток статистики движка + watchdog)
  void _stopWatch() {
    _timer?.cancel(); _timer = null;
    _tunEvents?.cancel(); _tunEvents = null;
    _stopWatchdog(); // вне сессии фоновой проверки нет: ручной disconnect/выход её гасят
  }

  // ── авто-реконнект ──

  /// Запланировать очередную попытку автопереподключения через паузу из reconnectDelay.
  /// Тумблер выключен — молча ничего не делаем (прежнее поведение: обрыв = «Отключено»).
  void _scheduleReconnect() {
    final delay = reconnectDelay(reconnectOn(), reconnectAttempt + 1);
    if (delay == null || _disposed) return;
    _reconnectTimer?.cancel();
    reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      // За паузу человек мог сам подключиться или размонтировать экран — тогда не лезем.
      // Реконнект ИЗ блокировки килл-свитча идёт с keepProxy сам: blocked ещё жив, и toggle()
      // (ветка conn==0) передаст его движку — прокси держится всю попытку.
      if (_disposed || conn != 0) return;
      // Тумблер могли выключить уже ПОСЛЕ планирования: перепроверяем при срабатывании —
      // иначе выключение «Автопереподключения» не отменяло запланированную попытку (LOW).
      if (!reconnectOn()) {
        reconnectAttempt = 0;
        notifyListeners(); // убрать «переподключение, попытка N» с Главной
        return;
      }
      toggle();
    });
    notifyListeners(); // на Главной появляется «переподключение, попытка N»
  }

  /// Снять серию автопереподключения: таймер и номер попытки. Зовут осознанные действия
  /// человека (подключить/отключить/отмена/выход/снятие блокировки) и успешное подключение.
  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    reconnectAttempt = 0;
  }

  // Остановить движок после неудачной/отменённой попытки. При живой блокировке килл-свитча
  // прокси НЕ снимаем (fail-closed: блокировка переживает неудачный реконнект), иначе снимаем
  // как раньше — иначе карточка «трафик заблокирован» осталась бы при уже прямом интернете.
  Future<void> _stopEngine() =>
      blocked ? TunnelEngine.instance.failClosed() : TunnelEngine.instance.disconnect();

  // накопление расхода за сессию + разовое предупреждение при большом расходе («Лимит трафика»)
  void _accTraffic() {
    // Движок шлёт down/up в kbps (килобитах/с) — см. NativeTunnel.events() контракт.
    // kbps → МБ за 1 сек: делим на 8 (бит→байт) и на 1024 (КБ→МБ). Без /8 расход завышался в 8 раз.
    // В демо ускоряем накопление (kDemoTrafficBoost), чтобы порог «Лимит трафика» был достижим и
    // тумблер можно было показать; в боевом режиме множитель = 1 (реальные байты не искажаем).
    _sessMB += (down + up) / (8 * 1024.0) * (gEngineReal ? 1 : kDemoTrafficBoost);
    if (trafWarnOn() && !_trafWarned && _sessMB >= kTrafficWarnMB) {
      _trafWarned = true;
      onToast(appLang == 'en'
          ? 'Session usage passed ${(kTrafficWarnMB / 1024).toStringAsFixed(0)} GB'
          : 'Расход за сессию превысил ${(kTrafficWarnMB / 1024).toStringAsFixed(0)} ГБ');
    }
  }

  // боевой режим: не удалось подключиться — честно откатываемся в «выключено».
  // Причину показываем ДВАЖДЫ намеренно: тост ловит момент (подключение могли запустить хоткеем
  // или из трея с любой вкладки), карточка на Главной держит её вместе с кнопкой «что делать».
  Future<void> _fail(int gen, String msg, {ConnFix fix = ConnFix.support}) async {
    if (_disposed || gen != _gen) return;
    _stopWatch();
    onSpin(false);
    conn = 0;
    // Килл-свитч: блокировка переживает НЕУДАЧНУЮ попытку. О блокировке судим по ФАКТУ в
    // системе (looksOurs), а не по флагу памяти SystemProxy.enabled: при реконнекте из
    // блокировки enable() мог упасть (macOS «Отмена» на запросе пароля), и хотя engine при
    // keepProxy прокси не снимает, флаг уже мог не отражать реальность — fail-open при
    // включённом килл-свитче недопустим (багхант, HIGH). Прокси сменился под нами или
    // тумблер успели выключить — блокировки фактически нет, карточку не выдумываем.
    var hold = false;
    if (kRealTunnel && holdProxyOnDrop(killSwitchOn(), TunnelEngine.kind())) {
      hold = await SystemProxy.looksOurs();
      if (_disposed || gen != _gen) return; // пока проверяли систему — началась новая попытка
    }
    if (blocked && !hold) TunnelEngine.instance.disconnect(); // fire-and-forget, как в reset()
    blocked = hold;
    failMsg = msg; failFix = fix;
    notifyListeners();
    onToast(msg);
    // Серия автопереподключения переживает неудачную попытку: при лежащей сети каждая попытка
    // падает (подписка не скачивается, туннель не поднимается) — перепланируем с нарастающей
    // паузой. Исключение — ConnFix.happ: сборка принципиально не умеет эти узлы, повторять
    // бессрочно бессмысленно. Первичная (ручная) неудача серии не создаёт: reconnectAttempt
    // там нулевой — реконнект начинается только после ОБРЫВА установленного соединения.
    if (reconnectAttempt > 0 && fix != ConnFix.happ) _scheduleReconnect();
  }

  // Держим ли при обрыве системный прокси (fail-closed). Только десктоп с xray удерживает
  // блокировку через неснятый прокси (порт мёртв → трафик умирает); на Android/iOS приложению
  // удерживать нечего (см. комментарий к TunnelEngine.failClosed) — объявлять там «трафик
  // заблокирован» было бы ложью. Вынесено в чистую функцию: правило покрыто killswitch_test.
  static bool holdProxyOnDrop(bool killSwitch, EngineKind kind) =>
      killSwitch && kind == EngineKind.desktopXray;

  // Пауза перед [attempt]-й попыткой автопереподключения (нумерация с 1): 2с, 5с, 15с, 30с,
  // дальше каждые 60с — бессрочно, пока не подключимся или человек не отменит серию.
  /// null — серии не быть: тумблер «Автопереподключение» выключен. Вынесено в чистую функцию:
  /// правило покрыто reconnect_test (сам обрыв без живого движка не воспроизвести — события
  /// шлёт только TunnelEngine, та же причина, что у killswitch_test).
  static Duration? reconnectDelay(bool toggleOn, int attempt) {
    if (!toggleOn) return null;
    const steps = [2, 5, 15, 30];
    final i = (attempt < 1 ? 1 : attempt) - 1;
    return Duration(seconds: i < steps.length ? steps[i] : 60);
  }

  // Продолжать ли автоперебор после того, как кандидат [attempt] (нумерация с 1) не пропустил
  // трафик: только в режиме «лучший сервер» и пока не исчерпали kMaxTryAttempts за нажатие.
  /// Ручной выбор — всегда стоп (поведение прежнее: причина + подсказка про «лучший сервер»).
  /// Чистая функция — правило покрыто roam_test (перебор без живого движка не воспроизвести).
  static bool roamContinues(bool bestServer, int attempt) =>
      bestServer && attempt < kMaxTryAttempts;

  /// Разрешён ли автоподхват CDN-рельсы после провала кандидата: только РУЧНОЙ выбор (в режиме
  /// «лучший сервер» перебор и так идёт через roamContinues), только restricted-сеть (см.
  /// пре-флайт в engine.dart), только ПЕРВАЯ попытка и только если сам кандидат — прямая нода
  /// (провал рельсы подхватывать нечем). Чистая функция — правило покрыто restricted_test.
  static bool roamRescue(bool bestServer, bool restricted, int attempt, Server candidate) =>
      !bestServer && restricted && attempt == 1 && !candidate.proto.startsWith('LTE');

  /// Спрятать прогресс автоперебора (успех/стоп/отмена). Без notifyListeners: вызывается рядом
  /// с _fail/_startSession, которые и так перерисуют экран.
  void _resetTry() {
    tryAttempt = 0;
    tryServer = '';
  }

  // движок сообщил об обрыве соединения — снимаем «подключено»
  void _dropped(int gen, {String? why}) {
    if (_disposed || gen != _gen) return;
    // Килл-свитч ≠ отключение по кнопке. Кнопка/reset()/выход — осознанные действия человека,
    // там прокси снимается всегда и интернет снова прямой. Здесь же обрыв НЕОЖИДАННЫЙ: при
    // включённом тумблере системный прокси НЕ снимаем (fail-closed) — порт мёртв, и трафик
    // умирает, а не течёт мимо туннеля. При выключенном тумблере — прежнее поведение.
    final hold = kRealTunnel && holdProxyOnDrop(killSwitchOn(), TunnelEngine.kind());
    // синхронизируем натив с UI: явно гасим движок, чтобы после обрыва он не остался в
    // полу-поднятом/реконнектящем состоянии (как reset()/disconnect-ветка toggle()).
    if (kRealTunnel) {
      if (hold) { TunnelEngine.instance.failClosed(); } else { TunnelEngine.instance.disconnect(); }
      gEngineReal = false;
    }
    _stopWatch();
    onSpin(false);
    conn = 0; secs = 0;
    blocked = hold;
    // Причину обрыва держим на экране так же, как причину неудачного старта: человек мог
    // отойти от компьютера и вернуться уже после того, как тост погас. При блокировке обычную
    // карточку причины заменяет карточка килл-свитча (см. home.dart) — fix ей не нужен.
    failMsg = (why != null && why.isNotEmpty) ? why : tr('Соединение разорвано');
    failFix = hold ? ConnFix.none : ConnFix.support;
    notifyListeners();
    // При блокировке тостим сам факт fail-closed (это важнее причины: интернет «пропал»
    // намеренно). Иначе — как раньше: причину от движка показываем ВСЕГДА, независимо от
    // тумблера «Обрыв соединения»: тумблер про фоновые уведомления, а это ответ на действие
    // пользователя — без него отказ выглядит как «нажал подключить, ничего не произошло».
    if (hold) {
      onToast(tr('VPN отвалился — трафик заблокирован'));
    } else if (why != null && why.isNotEmpty) {
      onToast(tr(why));
    } else if (dropAlertOn()) {
      onToast(tr('Соединение разорвано'));
    }
    // Авто-реконнект: обрыв сюда приходит ТОЛЬКО неожиданный — осознанные действия (кнопка
    // «Отключить», отмена коннекта, выход) _dropped не зовут и серию гасят сами. При включённом
    // тумблере планируем возврат с нарастающей паузой; при выключенном — молча остаёмся в
    // «Отключено», как раньше.
    _scheduleReconnect();
  }

  /// «Снять блокировку» — единственный выход из fail-closed без нового подключения:
  /// снимает системный прокси (интернет снова прямой) и возвращает обычное «Отключено».
  Future<void> unblock() async {
    if (!blocked) return;
    _cancelReconnect(); // «Снять блокировку» — осознанное решение не переподключаться
    blocked = false; // UI сразу возвращаем в «Отключено», прокси догоняет асинхронно
    notifyListeners();
    // disconnect идемпотентен: движок уже мёртв, здесь важно именно снятие прокси.
    await TunnelEngine.instance.disconnect();
    // Снятие могло не случиться: на macOS человек отменил системный запрос пароля — тогда
    // прокси остался указывать в мёртвый порт (интернета нет), а UI уже врёт «Отключено».
    // Проверяем факт и честно возвращаем карточку блокировки. looksOurs() работает на всех
    // трёх десктопах, поэтому проверка общая, а не только под macOS.
    if (kRealTunnel && TunnelEngine.kind() == EngineKind.desktopXray && await SystemProxy.looksOurs()) {
      if (_disposed) return;
      blocked = true;
      notifyListeners();
      onToast(tr('Не удалось снять блокировку — ответь на системный запрос пароля'));
    }
  }

  // полный сброс подключения (напр. при выходе из аккаунта): гасит поколение, таймеры, статус
  void reset() {
    _gen++;
    _cancelReconnect(); // выход — осознанное действие: серии автопереподключения здесь нет
    _resetTry(); // и автоперебор тоже гасится по смене поколения
    // боевой режим: гасим и НАСТОЯЩИЙ туннель — иначе после logout трафик продолжал бы идти через
    // движок (reset раньше только обнулял UI). fire-and-forget, как ветка disconnect в toggle().
    // Демо-режим (kRealTunnel=false) туннель не поднимает — там гасить нечего, поведение не меняем.
    if (kRealTunnel) { TunnelEngine.instance.disconnect(); gEngineReal = false; }
    _stopWatch();
    onSpin(false);
    conn = 0; secs = 0;
    // сброс — осознанное действие (logout/закрытие окна), а не обрыв: блокировки килл-свитча
    // здесь быть не должно, прокси уже снял disconnect выше.
    blocked = false;
    failMsg = null; failFix = ConnFix.none; // причина прошлого аккаунта новому не показывается
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopWatch();
    _cancelReconnect();
    super.dispose();
  }
}
