part of 'main.dart';

// ============================ NETWORK / EDGE-FUNCTIONS ============================
// Все сетевые вызовы к Supabase edge-функциям (app-login / app-sub / app-pair / rotate-secret /
// notify) + сетевые инструменты (спид-тест, проверка утечек) + авто-проверка обновлений.
extension ShellApi on ShellState {
  // Авто-проверка обновлений: сравниваем номер вшитой сборки с номером последнего релиза.
  // Тихо: любой сбой/таймаут/дев-сборка (kBuildNumber==0) — просто ничего не показываем.
  // Показ — ОДИН диалог на запуск вместо вечного баннера на Главной: «Скачать» / «Позже» /
  // «Больше не предлагать эту версию». Версию из prefs больше не спрашиваем, «Позже» держится
  // до следующего запуска само — _checkUpdate зовётся один раз, из initState.
  Future<void> _checkUpdate() async {
    if (kBuildNumber == 0) return;
    try {
      final r = await http.get(Uri.parse(kBuildNumberUrl)).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return;
      final latest = int.tryParse(r.body.trim()) ?? 0;
      if (latest <= kBuildNumber || !mounted) return;
      final p = await SharedPreferences.getInstance();
      // «Больше не предлагать эту версию» — выбор человека важнее нового запуска.
      if ((p.getInt('updateSkipBuild') ?? 0) >= latest) return;
      if (!mounted) return;
      _askUpdate(latest);
    } catch (_) {/* тихо */}
  }

  // Единственный диалог обновления. Работу не блокирует: обычный dismissible-диалог, любой
  // исход (включая тап мимо) до следующего запуска больше не спрашивает.
  void _askUpdate(int latest) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
        title: Text(tr('Доступно обновление'), style: disp(18, w: FontWeight.w700)),
        // фикс. ширина — как у остальных диалогов (иначе полоса на широком окне)
        content: SizedBox(width: 360, child: Text(
          appLang == 'en'
              ? 'bitaps VPN build $latest is out (yours is $kBuildNumber). Update now?'
              : 'Вышла сборка bitaps VPN $latest (у тебя $kBuildNumber). Обновить сейчас?',
          style: mono(13, c: C.text))),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final p = await SharedPreferences.getInstance();
              await p.setInt('updateSkipBuild', latest); // эту версию больше не предлагаем
            },
            child: Text(tr('Больше не предлагать эту версию'), style: mono(13, c: C.muted))),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Позже'), style: mono(13, c: C.muted))),
          TextButton(
            onPressed: () { Navigator.pop(ctx); _open(kDownloadUrl); },
            child: Text(tr('Скачать обновление'), style: mono(13, c: C.accent))),
        ],
      ),
    );
  }

  // Инструмент с сетью: окно с крутилкой → результат прямо в окне (видно всегда)
  // Ре-entrancy-гвард: двойной тап по «Спид-тест»/«Проверка утечек» не стартует 2 запроса + 2 диалога.
  Future<void> _runTool(String title, Future<String> Function() work) async {
    // молчаливый гвард сбивал с толку: закрыл окно тапом по фону — кнопка «не реагирует» до 25с.
    // Подсказываем, что инструмент ещё работает.
    if (_toolBusy) { _toast(tr('Уже выполняю — секунду')); return; }
    _toolBusy = true;
    final fut = work().whenComplete(() => _toolBusy = false);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => FutureBuilder<String>(
        future: fut,
        builder: (c, snap) {
          final done = snap.connectionState == ConnectionState.done;
          return AlertDialog(
            backgroundColor: C.bg2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
            title: Text(title, style: disp(18, w: FontWeight.w700)),
            // фикс. ширина: иначе однострочный результат растягивал бы диалог в полосу на широком окне
            content: SizedBox(width: 360, child: !done
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: C.accent)),
                    const SizedBox(width: 14),
                    Text(tr('Минутку…'), style: mono(13, c: C.muted)),
                  ])
                : Text(
                    snap.hasError
                        ? (appLang == 'en' ? "Couldn't run this.\n${snap.error}" : 'Не удалось выполнить.\n${snap.error}')
                        : (snap.data ?? ''),
                    style: mono(13, c: C.text))),
            actions: done
                ? [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Ок'), style: mono(13, c: C.accent)))]
                : null,
          );
        },
      ),
    );
  }

  // 2xx, но тело — не JSON-объект (пустое/HTML/массив). Это НЕ обрыв сети: возвращаем null, чтобы
  // вызывающий показал «непонятный ответ сервера», а не вводящее в заблуждение «нет интернета».
  Map<String, dynamic>? _asObj(String body) {
    try {
      final d = jsonDecode(body);
      if (d is Map<String, dynamic>) return d;
      if (d is Map) return d.cast<String, dynamic>();
    } catch (_) {/* не JSON */}
    return null;
  }

  String get _badRespErr => appLang == 'en'
      ? 'Unexpected server response. Try again later.'
      : 'Непонятный ответ сервера. Попробуй позже.';

  // ----- вход по ключу / реальная подписка / устройства -----
  void _applySub(Map<String, dynamic> d, {bool fresh = false}) {
    // явный вход в аккаунт (fresh) сбрасывает ранее импортированный чужой ключ — ключ аккаунта
    // должен применяться; авто-рефреш (fresh=false) НЕ перетирает вручную импортированный ключ
    if (fresh) { importedHost = null; customCfg = null; }
    subName = d['name']?.toString();
    subPlan = d['plan']?.toString();
    subExpires = d['expires_at']?.toString();
    subLimit = (d['device_limit'] is num) ? (d['device_limit'] as num).toInt() : null;
    subActive = d['active'] == true;
    // не перетираем вручную импортированный ключ авто-рефрешем подписки: importedHost==null у ключей
    // без URL-хоста (vmess/base64-ss) → доп. страхуемся на customCfg, иначе свой конфиг молча терялся
    if (d['vpn_key'] is String && importedHost == null && customCfg == null) keyStr = d['vpn_key'] as String;
    if (d['login_secret'] is String) loginSecret = d['login_secret'] as String;
    // devices_unknown: хаб молчал — «devices» в ответе пустой, но это НЕ «устройств нет».
    // Кэш не перетираем, а поднимаем флаг: кабинет покажет «не удалось получить список».
    devicesUnknown = d['devices_unknown'] == true;
    if (!devicesUnknown) {
      final dl = d['devices'];
      devices = (dl is List) ? dl.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : [];
    }
    // Статистика аккаунта (карточка «// статистика») + стрик-подсказка пейвола. app-sub отдаёт
    // их fail-soft (при сбое RPC поля null) — не перетираем закэшированное значение null'ом,
    // а вот 0 — честное значение, применяем. app-login stats не отдаёт — там поля просто отсутствуют.
    int? asInt(dynamic v) => (v is num) ? v.toInt() : null;
    if (d.containsKey('vip')) subVip = d['vip'] == true;
    subStreak = asInt(d['renewal_streak']) ?? subStreak;
    subNextBonus = asInt(d['next_renew_bonus']) ?? subNextBonus;
    if (d['member_since'] is String) statMemberSince = d['member_since'] as String;
    statPaidDays = asInt(d['total_paid_days']) ?? statPaidDays;
    statRefs = asInt(d['referral_count']) ?? statRefs;
    statTokens = asInt(d['token_balance']) ?? statTokens;
    _refreshTray(); // подписка/дни в меню трея (десктоп) — обновляем под новые данные аккаунта
  }

  // Ротация кода входа: старый код перестаёт работать, показываем новый.
  Future<void> _rotateSecret() async {
    if (tgId == null || appToken == null) { _toast(tr('Сначала войди')); return; }
    if (_rotating) return; // гвард от двойного тапа: без него двойной тап слал два POST
    rebuild(() => _rotating = true);
    _toast(tr('Меняю код…'));
    // Снимок сессии на момент запроса: за 20с таймаута юзер мог выйти и войти в ДРУГОЙ аккаунт —
    // поздний ответ старой сессии не должен ни разлогинить новую (401-ветка), ни подсадить ей
    // чужой login_secret (ok-ветка).
    final reqTgId = tgId;
    final reqToken = appToken;
    try {
      final r = await http
          .post(Uri.parse(kRotateSecret),
              headers: {'content-type': 'application/json', 'apikey': kApiKey},
              body: jsonEncode({'telegram_id': tgId, 'token': appToken}))
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (tgId != reqTgId || appToken != reqToken) return; // сессия сменилась во время запроса
      // silent: свой тост уже показываем ниже — иначе «Вышли из аккаунта» тут же перебивался бы
      if (r.statusCode == 401 || r.statusCode == 403) { _doLogout(silent: true); _toast(tr('Сессия истекла — войди снова')); return; }
      if (r.statusCode >= 500) { _toast(_srvErr(r.statusCode)); return; } // 5xx → «сервер недоступен», а не «нет интернета»
      final d = _asObj(r.body);
      if (d == null) { _toast(_badRespErr); return; }
      if (d['ok'] == true && d['login_secret'] is String) {
        rebuild(() => loginSecret = d['login_secret'] as String);
        // fire-and-forget, но с обработчиком: _save может бросить при двойном сбое хранилища
        // (secure + prefs) — без catchError это была бы необработанная async-ошибка после success-тоста
        _save().catchError((e) => debugPrint('_save after rotate failed: $e'));
        _toast(tr('Код входа обновлён ✓'));
      } else {
        _toast(tr('Не удалось сменить код'));
      }
    } catch (e) {
      debugPrint('_rotateSecret error: $e');
      if (mounted) _toast(_netErr);
    } finally {
      if (mounted) { rebuild(() => _rotating = false); } else { _rotating = false; }
    }
  }

  Future<void> _login([String? presetKey]) async {
    if (!mounted) return; // _pairLogin может звать после закрытия экрана
    if (_loggingIn) return; // гвард от двойного входа (двойной тап / _pairLogin + ручной)
    final key = (presetKey ?? _loginCtrl.text).trim();
    if (key.length < 12) {
      _toast(tr('Вставь VPN-ключ или Код входа'));
      return;
    }
    // Вход по VPN-ключу разрешён для ВСЕХ аккаунтов (решение владельца 2026-07-10). Ключ
    // (vless://…/trojan://… — любая схема из kSupportedKeySchemes) уходит как {key}; всё
    // остальное — как {secret} (UUID «Кода входа»). 403 use_login_secret остаётся обработан
    // на случай аварийного рубильника DISABLE_KEY_LOGIN на сервере. _pairLogin передаёт сюда
    // UUID → идёт по ветке secret.
    final isShareLink = kSupportedKeySchemes.any((s) => key.toLowerCase().startsWith(s));
    // Ссылка на подписку (https://…/u/<token>) — такой же credential, как ключ: app-login ищет
    // строку по точному совпадению vpn_key, а после перехода на подписки vpn_key и ЕСТЬ эта
    // ссылка. Гард isSubscriptionUrl узкий (только доверенный домен bitaps + путь /u/<token>).
    final isKey = isShareLink || isSubscriptionUrl(key);
    // Прочие http(s)-ссылки credential'ом не являются — отклоняем, как и раньше.
    if (!isKey && (key.startsWith('http://') || key.startsWith('https://'))) {
      _loginError(tr('Вход по VPN-ключу отключён. Вставь «Код входа» (UUID) из бота или письма.'));
      return;
    }
    if (!isKey && key.contains(RegExp(r'\s'))) {
      _toast(tr('Вставь «Код входа» (UUID) — без пробелов'));
      return;
    }
    _toast(tr('Вхожу…'));
    rebuild(() => _loggingIn = true); // гасим кнопку «Войти» на время запроса
    try {
      final r = await http
          .post(Uri.parse(kAppLogin),
              headers: {'content-type': 'application/json', 'apikey': kApiKey},
              body: jsonEncode(isKey ? {'key': key} : {'secret': key}))
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (r.statusCode >= 500) {
        _toast(_srvErr(r.statusCode));
        return;
      }
      if (r.statusCode == 401 || r.statusCode == 403) {
        // 403 use_login_secret: у аккаунта уже есть «Код входа» — вход по ключу закрыт (вектор захвата).
        // Ведём юзера на «Код входа», а не показываем невнятное «ключ не подошёл».
        final d403 = _asObj(r.body);
        // ошибка говорит про то, что юзер реально вводил: ключ или «Код входа»
        _loginError(d403 != null && d403['error'] == 'use_login_secret'
            ? tr('Вход по VPN-ключу отключён. Вставь «Код входа» (UUID) из бота или письма.')
            : (isKey
                ? tr('Этот ключ не подошёл. Возьми актуальный ключ в боте.')
                : tr('Этот код не подошёл. Возьми актуальный в боте (/start → Код входа).')));
        return;
      }
      if (r.statusCode == 429) {
        _loginError(tr('Слишком много попыток. Подожди минуту и попробуй снова.'));
        return;
      }
      final d = _asObj(r.body);
      if (d == null) { _toast(_badRespErr); return; }
      if (d['ok'] == true && d['telegram_id'] is num && d['app_token'] is String) {
        rebuild(() {
          tgId = (d['telegram_id'] as num).toInt();
          appToken = d['app_token'] as String;
          _applySub(d, fresh: true);
          _loginCtrl.clear();
        });
        _save().catchError((e) => debugPrint('_save after login failed: $e'));
        _toast(tr('Вход выполнен ✓'));
        // app-login не отдаёт статистику/стрик (это поля app-sub) → тихо дотягиваем сразу после
        // входа, чтобы карточка «// статистика» и стрик-подсказка пейвола не ждали ручного «Обновить»
        _refreshSub(silent: true);
      } else {
        _loginError(isKey
            ? tr('Ключ не найден. Возьми актуальный ключ в боте.')
            : tr('Код не найден. Возьми актуальный в боте (/start → Код входа).'));
      }
    } on TimeoutException catch (e) {
      debugPrint('_login timeout: $e');
      _toast(_netErr);
    } catch (e) {
      debugPrint('_login error: $e');
      _toast(_netErr);
    } finally {
      if (mounted) { rebuild(() => _loggingIn = false); } else { _loggingIn = false; }
    }
  }

  // Авто-вход через бота: старт привязки → открыть бота → опрашивать, пока не подтвердит → войти.
  // Гвард от двойного тапа: пока идёт привязка, повторный вызов игнорируем (иначе два диалога-ожидания).
  Future<void> _pairLogin() async {
    if (_pairing) return;
    // rebuild: первая фаза (POST action:start, до 15с) шла без индикации — кнопка выглядела мёртвой,
    // повторный тап молча глотался. Теперь кнопка гаснет через штатный disabled-стиль _btn.
    rebuild(() => _pairing = true);
    try {
      await _pairLoginInner();
    } finally {
      if (mounted) { rebuild(() => _pairing = false); } else { _pairing = false; }
    }
  }

  Future<void> _pairLoginInner() async {
    String token = '';
    try {
      final r = await http
          .post(Uri.parse(kAppPair),
              headers: {'content-type': 'application/json', 'apikey': kApiKey},
              body: jsonEncode({'action': 'start'}))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode >= 500) { _toast(_srvErr(r.statusCode)); return; } // 5xx → «сервер недоступен», а не «нет интернета»
      final d = _asObj(r.body);
      if (d == null) { _toast(_badRespErr); return; }
      if (d['ok'] != true || d['url'] == null || d['token'] is! String) {
        _toast(tr('Не удалось начать вход, попробуй ещё раз'));
        return;
      }
      token = d['token'] as String;
      await _open(d['url'] as String);
    } on TimeoutException {
      _toast(_netErr);
      return;
    } catch (e) {
      debugPrint('_pairLogin start: $e');
      _toast(_netErr);
      return;
    }
    if (!mounted) return;
    bool cancelled = false;
    // Держим ссылку на Navigator диалога, снятую ДО showDialog: если экран размонтируется во время
    // опроса, `mounted` станет false и закрыть окно через `context` уже нельзя → диалог утечёт.
    // Захваченный navigator позволяет закрыть окно из finally при любом исходе. dialogOpen страхует
    // от двойного pop (кнопка «Отмена» закрывает окно сама).
    final nav = Navigator.of(context, rootNavigator: true);
    bool dialogOpen = true;
    void closeDialog() {
      if (!dialogOpen) return;
      dialogOpen = false;
      if (nav.canPop()) nav.pop();
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        backgroundColor: C.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 6),
          SizedBox(width: 34, height: 34, child: CircularProgressIndicator(color: C.accent, strokeWidth: 3)),
          const SizedBox(height: 16),
          Text(tr('Подтверди вход в Telegram'), style: disp(15, w: FontWeight.w700, c: C.text)),
          const SizedBox(height: 6),
          Text(tr('Открылся бот — нажми «Запустить», затем «✅ Да, это я». Войду сам, как подтвердишь.'),
              textAlign: TextAlign.center, style: mono(12, c: C.muted)),
        ]),
        actions: [
          TextButton(onPressed: () { cancelled = true; dialogOpen = false; Navigator.pop(dctx); }, child: Text(tr('Отмена'), style: mono(13, c: C.muted))),
        ],
      ),
    );
    String? key;
    try {
      // опрашиваем до серверного TTL привязки (~15 мин), чтобы позднее подтверждение не терялось
      for (int i = 0; i < 180 && !cancelled; i++) {
        await Future.delayed(const Duration(seconds: 5));
        if (cancelled || !mounted) break;
        try {
          final cr = await http
              .post(Uri.parse(kAppPair),
                  headers: {'content-type': 'application/json', 'apikey': kApiKey},
                  body: jsonEncode({'action': 'check', 'token': token}))
              .timeout(const Duration(seconds: 10));
          // 429 у app-pair — ВРЕМЕННЫЙ (общий IP-бакет start+check, делится за NAT), а не «истёк/ошибка».
          // Тело {ok:false} иначе упало бы в break ниже и порвало живую привязку (TTL 15 мин) — ждём.
          if (cr.statusCode == 429) continue;
          final cd = _asObj(cr.body);
          if (cd == null) continue; // непонятный ответ — не рушим опрос, ждём следующей итерации
          // cd['key'] несёт login_secret (UUID) — вход по vpn_key закрыт на сервере (app-login → 403).
          // _login сам определит UUID как «Код входа» и залогинится по secret, а не по key.
          if (cd['key'] != null) { key = cd['key'] as String; break; }
          if (cd['pending'] != true && cd['ok'] != true) break; // истёк/ошибка
        } catch (_) {/* сеть моргнула — продолжаем опрос */}
      }
    } finally {
      // Закрываем окно во всех путях: успех, таймаут опроса, размонтирование экрана.
      // При «Отмене» dialogOpen уже false — closeDialog ничего не делает (не двойной pop).
      closeDialog();
    }
    if (cancelled) return; // окно уже закрыто «Отменой»
    if (key != null) {
      await _login(key);
    } else if (mounted) {
      _toast(tr('Не дождался подтверждения. Открой бота и нажми «Запустить».'));
    }
  }

  void _loginError(String msg) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: C.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
        title: Text(tr('Не удалось войти'), style: disp(18, w: FontWeight.w700)),
        content: Text(msg, style: mono(13, c: C.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Закрыть'), style: mono(13, c: C.muted))),
          TextButton(onPressed: () { Navigator.pop(context); _open(kBot); }, child: Text(tr('Открыть бота'), style: mono(13, c: C.accent))),
        ],
      ),
    );
  }

  Future<void> _refreshSub({String? del, bool silent = false}) async {
    if (!loggedIn) {
      if (!silent) _toast(tr('Сначала войди по ключу'));
      return;
    }
    // Re-entrancy-гвард (по образцу _pinging/_loggingIn): без него параллельные refresh
    // перезаписывали друг друга последним ответом — удалённое устройство «воскресало»,
    // а первый завершившийся гасил спиннер при ещё летящем втором.
    if (_subLoading) {
      // при удалении гвард роняет запрос молча → юзер думает, что устройство удалено. Явно
      // говорим, что не выполнено (кнопки корзины также гаснут по _subLoading в _deviceRow).
      if (!silent) {
        _toast(del != null
            ? tr('Идёт обновление — удаление не выполнено, повтори через секунду')
            : tr('Уже обновляю — секунду'));
      }
      return;
    }
    if (!silent) _toast(del != null ? tr('Удаляю устройство…') : tr('Обновляю…'));
    // _subVisibleLoading (спиннеры/дизейбл в UI) — только для явного рефреша: тихий фоновый рефреш
    // на старте (в т.ч. висящий 20с в офлайне) не должен показывать ложное «занято» поверх кэша.
    if (mounted) rebuild(() { _subLoading = true; if (!silent) _subVisibleLoading = true; });
    // Снимок сессии: за 20с таймаута юзер мог выйти и войти в другой аккаунт — поздний ответ
    // старой сессии не должен ни применяться к новой, ни разлогинивать её (см. проверку ниже).
    final reqTgId = tgId;
    final reqToken = appToken;
    try {
      final r = await http
          .post(Uri.parse(kAppSub),
              headers: {'content-type': 'application/json', 'apikey': kApiKey},
              // удаление устройства подтверждаем «Кодом входа» (login_secret) — сервер требует
              // сильный credential, а не только сессионный token (см. app-sub).
              body: jsonEncode({'telegram_id': tgId, 'token': appToken,
                if (del != null) 'del': del,
                if (del != null && loginSecret != null) 'secret': loginSecret}))
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (tgId != reqTgId || appToken != reqToken) return; // сессия сменилась во время запроса
      // 403 при удалении — не протухшая сессия, а требование «Кода входа»: не разлогиниваем.
      if (r.statusCode == 403 && del != null) {
        if (!silent) {
          _toast(loginSecret == null
              ? tr('Чтобы удалить устройство, нужен «Код входа». Открой его в боте (/start → Код входа) и войди по нему.')
              : tr('Не удалось подтвердить «Код входа» для удаления.'));
        }
        return;
      }
      if (r.statusCode == 401 || r.statusCode == 403) {
        // Разлогиниваем ТОЛЬКО на собственный «unauthorized» функции ({error:"unauthorized"}):
        // 401 от gateway/прокси и чужие 403 — транзиент, сессию из-за них не роняем.
        final d401 = _asObj(r.body);
        if (d401 != null && d401['error'] == 'unauthorized') {
          _doLogout(silent: true);
          // Даже при тихом фоновом рефреше (старт приложения) сообщаем явно: иначе человек
          // смотрел бы на устаревший кабинет, не зная, что сессия уже не его.
          _toast(tr('Сессия истекла — войди снова'));
        } else if (!silent) {
          _toast(_srvErr(r.statusCode));
        }
        return;
      }
      if (r.statusCode >= 500) {
        if (!silent) _toast(_srvErr(r.statusCode));
        return;
      }
      final d = _asObj(r.body);
      if (d == null) { if (!silent) _toast(_badRespErr); return; }
      if (d['ok'] == true) {
        // logout мог произойти во время запроса (mounted остаётся true, но loggedIn=false):
        // не воскрешаем подписку/ключ/устройства вышедшего аккаунта поздним ответом.
        if (!loggedIn) return;
        rebuild(() => _applySub(d));
        _save().catchError((e) => debugPrint('_save after refresh failed: $e'));
        _loadNodes(); // список серверов = узлы подписки; тихо, в фоне
        if (!silent) _toast(del != null ? tr('Устройство удалено ✓') : tr('Обновлено ✓'));
      } else if (!silent) {
        _toast(tr('Не удалось обновить'));
      }
    } on TimeoutException catch (e) {
      debugPrint('_refreshSub timeout: $e');
      if (!silent) _toast(_netErr);
    } catch (e) {
      debugPrint('_refreshSub error: $e');
      if (!silent) _toast(_netErr);
    } finally {
      if (mounted) rebuild(() { _subLoading = false; _subVisibleLoading = false; });
    }
  }

  Future<void> _sendSupport() async {
    if (_supportSending) return; // гвард от двойной отправки в поддержку
    final msg = _support.text.trim();
    if (msg.isEmpty) {
      _toast(tr('Сначала напиши сообщение'));
      return;
    }
    // Контакт обязателен: двусторонний мост поддержки работает только для тикетов, заведённых
    // в боте, поэтому на заявку из приложения отвечают на указанный контакт — и без него ответ
    // просто некуда отправить.
    final contact = _supportContact.text.trim();
    if (contact.isEmpty) {
      _toast(tr('Укажи, куда ответить — почта или @ник'));
      return;
    }
    _toast(tr('Отправляю…'));
    rebuild(() => _supportSending = true); // гасим кнопку «Отправить» на время запроса
    try {
      final r = await http.post(Uri.parse(kNotify),
          headers: {'content-type': 'application/json', 'apikey': kApiKey},
          body: jsonEncode({
            'type': 'support',
            'name': loggedIn
                ? (subName != null && subName!.isNotEmpty
                    ? subName!
                    : (appLang == 'en' ? 'Account #$tgId' : 'Аккаунт #$tgId'))
                : tr('Пользователь приложения'),
            // notify показывает email в сообщении группы, а contact кладёт в колонку заявки —
            // отдаём один и тот же контакт в оба поля, чтобы он не потерялся ни там, ни там.
            'email': contact,
            'contact': contact,
            'message': msg,
            'source': 'десктоп-приложение'
          }))
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (r.statusCode >= 200 && r.statusCode < 300) {
        _support.clear();
        rebuild(() {});
        // Контакт НЕ чистим: следующее обращение он писать заново не должен.
        _toast(tr('Отправлено ✓ — ответим на указанный контакт'));
      } else {
        _toast(r.statusCode >= 500
            ? _srvErr(r.statusCode)
            : (appLang == 'en' ? 'Send error (${r.statusCode})' : 'Ошибка отправки (${r.statusCode})'));
      }
    } catch (e) {
      debugPrint('_sendSupport error: $e');
      _toast(_netErr);
    } finally {
      if (mounted) { rebuild(() => _supportSending = false); } else { _supportSending = false; }
    }
  }

  // Замер пинга по всем доступным серверам (кнопка «Пинг» на Серверах). Замер честный —
  // реальный запрос по сети в момент нажатия, — но хост у всех строк один (наш бэкенд):
  // собственных нод по городам пока нет, поэтому это отклик канала пользователя, а не
  // конкретного города. http.get каждый раз поднимает свежее соединение (TCP+TLS) —
  // значения не схлопываются в кэшированный keep-alive. Результаты обновляются построчно.
  /// [silent] — автопроверка сразу после загрузки узлов: молча, без тостов об успехе и о сети.
  /// Без неё весь список стоял бы прочерками, пока человек не догадается нажать «Проверить».
  ///
  /// Что здесь происходит и почему именно так. Раньше это был TCP-коннект до адреса узла, и
  /// он врал: при глушении интернета порт прямого узла отвечает, а трафик сквозь него не идёт.
  /// Человек видел зелёный отклик у всех серверов, подключался — и ничего не грузилось, тогда
  /// как узлы через CDN работали. Теперь на каждый узел поднимается временный экземпляр движка
  /// и сквозь него тянется маленький ответ из сети: дошло — узел рабочий, и число рядом с ним
  /// это честное время ответа СКВОЗЬ туннель; не дошло — узел непригоден и выбирать его нечего.
  ///
  /// При ПОДНЯТОМ туннеле замер тоже работает: временный экземпляр движка идёт к узлу сам
  /// (на десктопе его сокеты в системный прокси не попадают, на Android плагин умеет замер
  /// поверх живого VpnService), а если сквозной замер не ответил — фолбэк на живой пинг из
  /// observatory поднятого туннеля. Разница в итоге: приговор «узел пропускает трафик С ЭТОЙ
  /// сети» выносим только по прямому замеру (conn == 0) — путь пакета при включённом VPN не
  /// совпадает с выключенным состоянием, и переносить его вывод на прямую сеть было бы ложью.
  /// Поэтому при conn != 0 обновляем только живое число сессии (pingMeasured), не приговор.
  Future<void> _pingServers({bool silent = false}) async {
    if (_pinging) return; // гвард от двойного тапа
    final viaTunnel = conn != 0; // замер при поднятом туннеле: числа есть, приговоры не трогаем
    rebuild(() => _pinging = true);
    var okCount = 0, badCount = 0;
    try {
      final targets = subNodes.where((n) => n.server.isNotEmpty).toList();
      // Без узлов проверять нечего — и это НЕ проблема сети. Раньше пустой список давал
      // «нет связи с интернетом», хотя интернет был, а не было подписки.
      if (targets.isEmpty) {
        if (!silent) _toast(tr('Сначала нужны серверы — обнови подписку'));
        return;
      }
      // Отпечаток сети снимаем ОДИН раз на проверку: приговоры привязаны к сети, потому что
      // узел, закрытый у мобильного оператора, прекрасно работает с домашнего Wi-Fi. При замере
      // сквозь туннель приговоры не пишем — и отпечаток не нужен.
      var net = netId;
      if (!viaTunnel) {
        net = await _networkId();
        if (mounted) rebuild(() => netId = net);
      }

      // Применить итог замера одного узла (общий для быстрого флот-пути и per-node фолбэка):
      // приговор пишем только при прямом замере (conn == 0), сквозь туннель — лишь живое число.
      void applyOne(SubNode n, int? ms) {
        if (viaTunnel) {
          // Только живое число сессии: молчащий узел старый ручной замер НЕ стирает —
          // замер сквозь VPN ничего не говорит о прямой доступности.
          rebuild(() {
            if (ms != null) { pingMeasured[n.tag] = ms; okCount++; } else { badCount++; }
            pingDone++;
          });
        } else {
          final v = NodeVerdict(ok: ms != null, ms: ms, at: DateTime.now(), net: net);
          rebuild(() {
            nodeVerdicts[n.tag] = v;
            if (ms != null) { pingMeasured[n.tag] = ms; okCount++; }
            else { pingMeasured.remove(n.tag); badCount++; }
            pingDone++;
          });
        }
      }

      // Проверка тяжелее TCP-коннекта. На десктопе сначала БЫСТРЫЙ путь: весь флот одним
      // временным процессом движка — обсерватория отдаёт alive/rtt каждого узла за ~4 с
      // (probeFleet), тогда как старый путь поднимал процесс xray на КАЖДЫЙ узел и шёл
      // 10–12 с. Работает и при поднятом туннеле: временный процесс идёт к узлам напрямую
      // (его сокеты в системный прокси не попадают), поэтому «отключитесь для замера» не
      // нужно НИГДЕ. Упал или не покрыл всех — остаток добиваем per-node перебором пулом
      // (runPooled): одновременность — pingLanes (на Android временные экземпляры живут на
      // разных socks-портах по полосе — см. probe(lane)).
      final lanes = TunnelEngine.pingLanes(Platform.isAndroid);
      rebuild(() { pingTotal = targets.length; pingDone = 0; });
      var rest = targets;
      if (TunnelEngine.kind() == EngineKind.desktopXray) {
        final fleet = await TunnelEngine.instance.probeFleet(targets);
        if (fleet != null) {
          rest = [for (final n in targets) if (!fleet.containsKey(n.tag)) n];
          for (final n in targets) {
            if (fleet.containsKey(n.tag)) applyOne(n, fleet[n.tag]);
          }
        }
        if (!mounted) return;
      }
      await runPooled<void>([
        for (var i = 0; i < rest.length; i++)
          () async {
            final n = rest[i];
            var ms = await TunnelEngine.instance.probe(n, lane: i % lanes);
            // Сквозной замер молчит — фолбэк на живой пинг observatory поднятого туннеля.
            if (ms == null && viaTunnel) ms = _observatoryPing(n.tag);
            applyOne(n, ms);
          },
      ], lanes);
      if (!viaTunnel) await _saveVerdicts();

      // Выбор «лучшего сервера» пересобираем ПОСЛЕ проверки: до неё приговоров не было, и
      // режим держал бы узел, через который ничего не грузится.
      if (mounted && bestServer && conn == 0) rebuild(() => server = serverForMode(mode));
      if (!silent) {
        _toast(viaTunnel
            ? (okCount > 0
                ? (appLang == 'en'
                    ? 'Measured through the active tunnel: $okCount answered, $badCount silent'
                    : 'Замер сквозь активный туннель: $okCount отвечают, $badCount молчат')
                : (appLang == 'en'
                    ? 'No server answered even through the tunnel'
                    : 'Сквозь туннель не ответил ни один сервер'))
            : (okCount > 0
                ? (appLang == 'en'
                    ? 'Checked: $okCount working, $badCount not passing traffic'
                    : 'Проверено: $okCount рабочих, $badCount не пропускают трафик')
                : (appLang == 'en'
                    ? 'None of the servers is passing traffic right now'
                    : 'Сейчас ни один сервер не пропускает трафик')));
      }
    } finally {
      if (mounted) { rebuild(() => _pinging = false); } else { _pinging = false; }
    }
  }

  /// Сохранить приговоры. Отдельно от общего _save: он вызывается часто и синхронно с UI,
  /// а тут запись большого JSON — незачем дёргать её на каждый чих.
  Future<void> _saveVerdicts() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('nodeVerdicts',
          jsonEncode({for (final e in nodeVerdicts.entries) e.key: e.value.toJson()}));
      await p.setString('netId', netId);
    } catch (e) {
      debugPrint('_saveVerdicts failed: $e');
    }
  }

  /// Отпечаток сети — две первые группы внешнего адреса. Нужен, чтобы приговор по узлу,
  /// полученный у мобильного оператора, не показывался как истина на домашнем Wi-Fi.
  /// Не получилось узнать — возвращаем пустую строку: тогда приговоры считаются общими,
  /// это хуже, но честнее, чем приписать их чужой сети.
  Future<String> _networkId() async {
    try {
      final r = await http.get(Uri.parse('${kFnBase}whoami')).timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return '';
      final ip = '${(json.decode(r.body) as Map)['ip'] ?? ''}';
      final parts = ip.split(ip.contains(':') ? ':' : '.');
      if (parts.length < 2) return '';
      return '${parts[0]}.${parts[1]}';
    } catch (_) {
      return '';
    }
  }

  /// Подтянуть узлы подписки БЕЗ подключения — чтобы список серверов был живым сразу после
  /// входа, а не только после первого коннекта. Тихо: сбой сети просто оставляет прежний список.
  /// Под «белыми списками» выдача недоступна — fetchSubscriptionCached молча поднимает список
  /// из кэша (TTL 7 дней), а экран «Серверы» показывает пометку «из кэша от <дата>» (subCacheAt).
  /// Идентификатор устройства тот же, что при подключении, — лишний слот не занимаем.
  Future<void> _loadNodes() async {
    final key = keyStr.trim();
    if (!isSubscriptionUrl(key) || hwid.isEmpty) return;
    try {
      final sub = await fetchSubscriptionCached(key, hwid: hwid, deviceOs: Platform.operatingSystem);
      if (!mounted) return;
      // Отметка свежести — только по успешному ответу сервиса ИЗ СЕТИ: открытие «Серверов» гоняет
      // fetch не чаще раза в 5 минут (см. _maybeRefreshNodes), а сбой/кэш не должен его откладывать —
      // иначе после ухода «белых списков» свежий список ждал бы лишние минуты.
      if (sub.ok && sub.cachedAt == null) nodesFetchedAt = DateTime.now();
      // Причину пустого списка запоминаем и показываем на экране «Серверы». Сервис выдачи
      // отвечает осмысленно («Лимит устройств исчерпан», «Подписка истекла»), а раньше этот
      // текст выбрасывался — человек видел вместо серверов заглушку и не понимал, что не так.
      final note = sub.notice;
      if (sub.ok && sub.nodes.isNotEmpty) {
        rebuild(() => subNotice = null);
        _applyNodes(sub.nodes, cacheAt: sub.cachedAt);
        // Один автозамер на сессию: иначе список серверов встречает человека сплошными
        // прочерками, а карточка сервера на Главной — без отклика вовсе.
        if (pingMeasured.isEmpty) _pingServers(silent: true);
      } else if (note != null && note.isNotEmpty) {
        rebuild(() => subNotice = note);
      }
    } catch (e) {
      debugPrint('_loadNodes: $e');
    }
  }

  /// Подтянуть узлы при открытии экрана «Серверы», но не чаще раза в 5 минут: свежий список
  /// не гоняем впустую, а новые серверы подписки обязаны появляться без перелогина (раньше
  /// список обновлял только старт приложения — люди не видели новые ноды неделями).
  Future<void> _maybeRefreshNodes() async {
    final at = nodesFetchedAt;
    if (at != null && DateTime.now().difference(at) < const Duration(minutes: 5)) return;
    await _loadNodes();
  }

  /// Публичная статистика доступности нод (спарклайны внизу «Серверов»). Тот же троттлинг
  /// 5 минут, что у _maybeRefreshNodes. Сбой сети/формата — НЕ ломает страницу: поднимаем
  /// флаг nodeStatsFailed, и блок честно показывает «данные недоступны» (под «белыми
  /// списками» origin мёртв — это ожидаемый путь, а не авария).
  Future<void> _maybeRefreshNodeStats() async {
    if (_statsLoading) return;
    final at = nodeStatsFetchedAt;
    if (at != null && DateTime.now().difference(at) < const Duration(minutes: 5)) return;
    _statsLoading = true;
    try {
      final r = await http.get(Uri.parse(kNodeStatsUrl)).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (r.statusCode != 200) {
        rebuild(() => nodeStatsFailed = true);
        return;
      }
      final parsed = parseNodeStats(r.body);
      rebuild(() {
        if (parsed != null) {
          nodeStats = parsed;
          nodeStatsFailed = false;
          nodeStatsFetchedAt = DateTime.now();
        } else {
          nodeStatsFailed = true; // ответ не по форме — как сбой сети
        }
      });
    } catch (_) {
      if (mounted) rebuild(() => nodeStatsFailed = true);
    } finally {
      _statsLoading = false;
    }
  }


  Future<void> _leakCheck() => _runTool(tr('Проверка утечек'), () async {
        final r = await http.get(Uri.parse('https://api.ipify.org?format=json')).timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) {
          throw Exception(appLang == 'en' ? 'server returned ${r.statusCode}' : 'сервер вернул ${r.statusCode}');
        }
        final ip = (jsonDecode(r.body) as Map)['ip'];
        if (ip == null) throw Exception(tr('IP не получен'));
        return appLang == 'en'
            ? 'Your current external IP:\n\n$ip\n\nWith the VPN on it changes to the server address — that shows traffic goes through the tunnel.'
            : 'Твой текущий внешний IP:\n\n$ip\n\nС включённым VPN он сменится на адрес сервера — так видно, что трафик идёт через туннель.';
      });

  Future<void> _speedTest() => _runTool(tr('Тест скорости'), () async {
        final sw = Stopwatch()..start();
        final r = await http.get(Uri.parse('https://speed.cloudflare.com/__down?bytes=4000000')).timeout(const Duration(seconds: 25));
        if (r.statusCode != 200) {
          throw Exception(appLang == 'en' ? 'server returned ${r.statusCode}' : 'сервер вернул ${r.statusCode}');
        }
        sw.stop();
        final secs = (sw.elapsedMilliseconds / 1000.0).clamp(0.001, double.infinity);
        final mbps = r.bodyBytes.length * 8 / secs / 1e6;
        final mb = r.bodyBytes.length / 1048576;
        return appLang == 'en'
            ? 'Download speed: ${mbps.toStringAsFixed(1)} Mbps\n\nGot ${mb.toStringAsFixed(1)} MB in ${sw.elapsedMilliseconds} ms\n(real measurement via Cloudflare)'
            : 'Скорость загрузки: ${mbps.toStringAsFixed(1)} Mbps\n\nПолучено ${mb.toStringAsFixed(1)} MB за ${sw.elapsedMilliseconds} мс\n(реальный замер через Cloudflare)';
      });
}
