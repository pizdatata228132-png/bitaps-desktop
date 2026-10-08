part of '../main.dart';

// ============================ ACCOUNT (Кабинет: вход, подписка, ключ, устройства) ============================
// Экран «вход» отдельного виджета не имеет — форма входа встроена в _subCard() при !loggedIn.

// коды тарифов из бэкенда (mo/q/h/yr/trial) → человекочитаемые названия,
// чтобы в кабинете не светился сырой код («Тариф «mo»» / бейдж «MO»)
const Map<String, String> _planNames = {
  'mo': '1 месяц', 'q': '3 месяца', 'h': '6 месяцев', 'yr': '12 месяцев', 'trial': 'Пробный период',
};
const Map<String, String> _planShorts = {
  'mo': '1 МЕС', 'q': '3 МЕС', 'h': '6 МЕС', 'yr': '1 ГОД', 'trial': 'ТРИАЛ',
};
const Map<String, int> _planTotalDays = {'mo': 30, 'q': 90, 'h': 180, 'yr': 365, 'trial': 3};

extension ShellAccount on ShellState {
  // Вставка ключа из буфера. Ключ bitaps = credential ВХОДА: по нему входим в аккаунт (подписка,
  // устройства, кабинет), а не просто подменяем строку подключения — «вставила ключ и просто
  // подключила VPN» владелицу не устраивало. Чужой (не-bitaps) ключ в аккаунт не пустит —
  // для него остаётся старый импорт «только для подключения» (модель Happ).
  Future<void> _importKey() async {
    final data = await Clipboard.getData('text/plain');
    final t = (data?.text ?? '').trim();
    await _importKeyString(t, fromClipboard: true);
  }

  // Общее ядро импорта ключа: используется и вставкой из буфера (_importKey), и deep-link'ом
  // (bitaps://import?key=…). Один и тот же trusted-host гейт и путь входа для обоих источников.
  Future<void> _importKeyString(String raw, {bool fromClipboard = false}) async {
    final t = raw.trim();
    // Ссылка на подписку bitaps (/u/<token>) — штатный формат ключа с переходом на подписки.
    // Хост в ней уже проверен isSubscriptionUrl (только доверенные домены bitaps), поэтому
    // trusted-host гейт ниже ей не нужен: сразу входим по ней либо обновляем кабинет.
    if (isSubscriptionUrl(t)) {
      if (!mounted) return;
      if (!loggedIn) {
        await _login(t);
      } else {
        rebuild(() { keyStr = t; importedHost = null; customCfg = null; });
        await _save();
        await _refreshSub();
      }
      return;
    }
    // Сторонняя подписка по http(s)-ссылке (НЕ bitaps): скачивается как подписка при обновлении
    // списка и при подключении (fetchSubscriptionCached allowForeign). Раньше такая ссылка
    // отвергалась «Это не VPN-ключ» — сторонний сервис добавить было невозможно вообще (08.10).
    if (t.toLowerCase().startsWith('http://') || t.toLowerCase().startsWith('https://')) {
      final host = _hostOf(t);
      final ok = await _confirmForeignHost(host ?? tr('неизвестный хост'));
      if (ok != true) return;
      if (!mounted) return;
      rebuild(() {
        keyStr = t;
        // sentinel '?' — как у чужого ключа выше: маркер «есть ручной импорт», чтобы авто-рефреш
        // аккаунта не перетёр его молча (гард importedHost==null в _applySub).
        importedHost = host ?? '?';
        customCfg = null;
      });
      _save();
      _toast(appLang == 'en' ? 'Subscription added — refreshing servers…' : 'Подписка добавлена — обновляю серверы…');
      await _loadNodes(); // показать её серверы в списке сразу, а не только при коннекте
      return;
    }
    // Иначе принимаем только сам VPN-ключ (любая схема из kSupportedKeySchemes — как гард
    // коннекта и «Свой конфиг»). Прочие http(s)-ссылки не принимаем: раньше такая ссылка молча
    // сохранялась как ключ и коннект падал.
    if (!kSupportedKeySchemes.any((s) => t.toLowerCase().startsWith(s))) {
      _toast(fromClipboard ? tr('В буфере нет VPN-ключа') : tr('Это не VPN-ключ'));
      return;
    }
    final host = _hostOf(t);
    // null/непарсящийся хост = НЕ доверенный → предупреждаем (раньше null молча проходил мимо гейта)
    if (host == null || !_isTrustedHost(host)) {
      final ok = await _confirmForeignHost(host ?? tr('неизвестный хост'));
      if (ok != true) return;
      if (!mounted) return;
      rebuild(() {
        keyStr = t;
        // sentinel '?' когда хост не распарсился: importedHost==null означало бы «ключ не импортирован»,
        // и после рестарта авто-рефреш (_applySub гард importedHost==null) молча перетёр бы ручной
        // ключ ключом аккаунта. Непустой маркер защищает импорт (importedHost нигде не отображается).
        importedHost = host ?? '?';
      });
      _save();
      _toast(host != null
          ? (appLang == 'en' ? 'Key replaced with $host ✓' : 'Ключ заменён на $host ✓')
          : tr('Ключ заменён ✓'));
      return;
    }
    if (!mounted) return;
    // Ключ bitaps: не залогинены → входим по нему (app-login подтянет подписку/устройства и сам
    // применит актуальный ключ аккаунта через _applySub). Уже залогинены → просто обновим кабинет.
    if (!loggedIn) {
      await _login(t);
    } else {
      await _refreshSub();
    }
  }

  int? _daysLeft() {
    if (subExpires == null) return null;
    final e = DateTime.tryParse(subExpires!);
    if (e == null) return null;
    // округляем ВВЕРХ по минутам: пока есть остаток времени — показываем ≥1 день,
    // «истекла» (≤0) только когда срок реально вышел (раньше 1-23ч флорились в 0 = «истекла» на сутки раньше)
    return (e.toUtc().difference(DateTime.now().toUtc()).inMinutes / 1440).ceil();
  }

  // Русские склонения дней: 1 день / 2-4 дня / 5+ дней
  String _pluralDays(int n) {
    final n10 = n % 10, n100 = n % 100;
    if (n10 == 1 && n100 != 11) return 'день';
    if (n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14)) return 'дня';
    return 'дней';
  }

  // Лимит устройств: число, либо «…» при загрузке, либо «—» если неизвестно
  String get _limitStr => subLimit != null ? '$subLimit' : (_subVisibleLoading ? '…' : '—');

  // баннер-напоминание при близком/истёкшем сроке (тумблер «Подписка истекает») —
  // ведёт в нативный пейвол (_openPaywall); тот сам различает веб-аккаунт (отрицательный
  // telegram_id → pay.html) и обычный (deep-link в бота).
  Widget _expiryBanner(int days) {
    final expired = days <= 0;
    return GestureDetector(
      onTap: _openPaywall,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(color: C.warn.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.warn.withValues(alpha: 0.5))),
        child: Row(children: [
          Icon(Icons.notifications_active, color: C.warn, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(expired ? tr('Подписка истекла') : tr('Подписка истекает'), style: disp(14, w: FontWeight.w700, c: C.warn)),
            const SizedBox(height: 2),
            Text(
              expired
                  ? tr('Продли, чтобы вернуть доступ')
                  : (appLang == 'en'
                      ? '$days ${days == 1 ? 'day' : 'days'} left — renew early'
                      : 'Осталось $days ${_pluralDays(days)} — продли заранее'),
              style: mono(11, c: C.muted)),
          ])),
          const SizedBox(width: 8),
          Text(tr('Продлить →'), style: mono(12, c: C.accent)),
        ]),
      ),
    );
  }

  Widget _account() {
    final daysLeft = _daysLeft(); // считаем один раз за билд (tryParse+арифметика), переиспользуем ниже
    return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(tr('Кабинет'), style: disp(26, w: FontWeight.w800)),
          const SizedBox(height: 18),
          _profileCard(),
          const SizedBox(height: 14),
          if (loggedIn && tgl3 && daysLeft != null && daysLeft <= 3) ...[_expiryBanner(daysLeft), const SizedBox(height: 14)],
          _subCard(),
          const SizedBox(height: 14),
          _keyCard(),
          if (loggedIn) ...[const SizedBox(height: 14), _devicesCard()],
          // «// статистика» — между подпиской и рефералкой: честные факты аккаунта из app-sub
          // (никаких трафик-цифр — туннель демо)
          if (loggedIn) ...[const SizedBox(height: 14), _statsCard()],
          const SizedBox(height: 14),
          _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [_gIcon(Icons.card_giftcard), const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _kicker(tr('пригласи друзей')), const SizedBox(height: 3), Text(tr('Приглашай — получай бонусные дни'), style: mono(11))]))]),
            const SizedBox(height: 10),
            // бот реально начисляет и дни, и токены (TOKENS_PER_REFERRAL=100) — не занижаем обещание
            Text(tr('▸ +14 дней и +100 🪙 за каждого друга, кто оформит первую подписку\n▸ начисляем автоматически'), style: mono(12, c: C.muted)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _btn(tr('Поделиться ссылкой'), kind: 1, icon: Icons.share, onTap: () {
                if (!loggedIn) { _toast(tr('Войди, чтобы получить свою реферальную ссылку')); return; }
                if (tgId != null && tgId! < 0) { _toast(tr('Рефералы — через нашего Telegram-бота')); _open(kBot); return; } // веб-аккаунт: реф работает только в Telegram
                _copy('https://t.me/bitaps_vpn_auth_bot?start=ref$tgId', tr('Реферальная ссылка'));
              })),
              const SizedBox(width: 12),
              // Реф-QR: друг наводит камеру → сразу в бота с реф-параметром. Веб-аккаунт (tgId<0)
              // и гость реф-ссылки не имеют — показываем осмысленный тост вместо пустого QR.
              SizedBox(width: 52, child: _btn('QR', kind: 2, onTap: () {
                if (!loggedIn) { _toast(tr('Войди, чтобы получить свою реферальную ссылку')); return; }
                if (tgId != null && tgId! < 0) { _toast(tr('Рефералы — через нашего Telegram-бота')); return; }
                _showQr('https://t.me/bitaps_vpn_auth_bot?start=ref$tgId', tr('Реферальный QR'),
                    hint: tr('Друг наводит камеру — и попадает в бота по твоей ссылке'));
              })),
            ]),
          ])),
          const SizedBox(height: 14),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Раньше кнопка выкидывала в Telegram-бота: интерес возник в приложении, а рассказ
            // про товар — снаружи, и половина людей туда не доходила. Теперь у коробки свой экран.
            onTap: _openBBox,
            child: _card(strong: true, child: Row(children: [
              _gIcon(Icons.router),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('B-box — VPN для всего дома'), style: disp(16, w: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(tr('устройство для дома · 15 000 ₽'), style: mono(12, c: C.accent)),
              ])),
              Icon(Icons.chevron_right, size: 18, color: C.muted),
            ])),
          ),
          const SizedBox(height: 14),
          _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [_gIcon(Icons.forum), const SizedBox(width: 12), _kicker(tr('поддержка'))]),
            const SizedBox(height: 12),
            // Куда ответить. Раньше заявка уходила с пустым контактом: в группе поддержки стояло
            // «✉️ E-mail:» ни с чем, а обратный мост работает только для тикетов, заведённых в
            // боте. Человек видел «Отправлено ✓» и ждал ответа, которому некуда было прийти.
            Container(padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: C.field, borderRadius: BorderRadius.circular(10)),
              child: TextField(
                controller: _supportContact,
                maxLines: 1,
                style: mono(13, c: C.text),
                cursorColor: C.accent,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(isDense: true, border: InputBorder.none,
                  contentPadding: EdgeInsets.zero, hintText: tr('Почта или @ник — куда ответить'), hintStyle: mono(13, c: C.muted)),
              )),
            const SizedBox(height: 10),
            Container(padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: C.field, borderRadius: BorderRadius.circular(10)),
              // Ctrl/Cmd+Enter отправляет (обычный Enter оставляем для переноса — сообщение
              // многострочное): control для Win/Linux, meta для macOS. _sendSupport сам гвардит пустое.
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter, control: true): _sendSupport,
                  const SingleActivator(LogicalKeyboardKey.enter, meta: true): _sendSupport,
                },
                child: TextField(
                  controller: _support,
                  maxLines: 3,
                  style: mono(13, c: C.text),
                  cursorColor: C.accent,
                  decoration: InputDecoration(isDense: true, border: InputBorder.none,
                    contentPadding: EdgeInsets.zero, hintText: tr('Опиши проблему…'), hintStyle: mono(13, c: C.muted)),
                ),
              )),
            const SizedBox(height: 12),
            _btn(tr('Отправить'), kind: 0, icon: Icons.send, onTap: _supportSending ? null : _sendSupport),
            const SizedBox(height: 10),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _open(kSupport),
              child: Center(child: Text(tr('или напиши @bitapssupport'), style: mono(12, c: C.accent)))),
          ])),
          const SizedBox(height: 14),
          _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [_gIcon(Icons.help), const SizedBox(width: 12), _kicker(tr('частые вопросы'))]),
            const SizedBox(height: 8),
            for (final f in faqs) _faqRow(f),
          ])),
          const SizedBox(height: 18),
          // номер сборки — чтобы релизные версии были различимы (дев-сборка kBuildNumber==0 — без него)
          Center(child: Text(kBuildNumber > 0 ? 'bitaps vpn · v1.0 · build $kBuildNumber' : 'bitaps vpn · v1.0', style: mono(11, c: C.muted))),
        ],
      );
  }

  Widget _profileCard() {
    final name = loggedIn
        ? ((subName != null && subName!.isNotEmpty)
            ? subName!
            : (appLang == 'en' ? 'Account (#$tgId)' : 'Аккаунт (#$tgId)'))
        : tr('Вход не выполнен');
    // characters.first — целый графемный кластер: Telegram-имена часто начинаются с эмодзи/флага
    // (суррогатная пара), а substring(0,1) резал бы её пополам → «�» в аватаре.
    final initial = name.isNotEmpty ? name.characters.first.toUpperCase() : 'A';
    return _card(strong: true, child: Row(children: [
      Container(width: 60, height: 60, alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, gradient: accentGrad,
          boxShadow: [BoxShadow(color: C.accent.withValues(alpha: 0.4), blurRadius: 18)]),
        child: Text(initial, style: disp(26, w: FontWeight.w800, c: C.bg))),
      const SizedBox(width: 14),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // maxLines/ellipsis: длинное имя из Telegram (до ~64 симв.) иначе разворачивало карточку в 3 строки
        Text(name, style: disp(20, w: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 3),
        // нейтральное «Вход выполнен»: способов входа три (Telegram-пейринг / ключ / код) —
        // не угадываем, каким именно вошли
        Text(loggedIn ? tr('Вход выполнен') : tr('Войди через Telegram, чтобы активировать подписку'), style: mono(11)),
        const SizedBox(height: 6),
        Row(children: loggedIn
            ? [_badge(subActive ? tr('Активна') : tr('Не активна'), subActive ? C.ok : C.muted),
               if (subPlan != null) ...[const SizedBox(width: 6), _badge(_planShort(subPlan!), C.accent)]]
            : [_badge(tr('Гость'), C.muted)]),
      ])),
      // IconButton вместо голой иконки: тап-таргет ≥40px + tooltip/семантика (как в _deviceRow)
      if (loggedIn) IconButton(
        onPressed: _logout,
        iconSize: 20,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        splashRadius: 22,
        tooltip: tr('Выйти'),
        icon: Icon(Icons.logout, color: C.muted)),
    ]));
  }

  String _planLabel(String? p) {
    if (p == null) return tr('Нет подписки');
    if (p == 'trial') return tr('Пробный период');
    final n = _planNames[p] ?? p;
    return appLang == 'en' ? 'Plan "${tr(n)}"' : 'Тариф «$n»';
  }
  String _planShort(String p) => tr(_planShorts[p] ?? p.toUpperCase());

  Widget _subCard() {
    if (!loggedIn) {
      return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [_gIcon(Icons.login), const SizedBox(width: 12), _kicker(tr('вход'))]),
        const SizedBox(height: 10),
        Text(tr('Войди через Telegram — приложение само подхватит твою подписку и ключ. Без ручного копирования.'), style: mono(12)),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: _btn(tr('Войти через Telegram'), kind: 0, icon: Icons.send, onTap: _pairing ? null : _pairLogin)),
        const SizedBox(height: 14),
        // Вход по VPN-ключу снова разрешён на сервере (решение владельца 2026-07-10): ключ —
        // основной credential, «Код входа» (UUID) работает как раньше. _login сам различает:
        // vless://… уходит как {key}, UUID — как {secret}.
        Text(tr('или вставь VPN-ключ / Код входа:'), style: mono(11, c: C.muted)),
        const SizedBox(height: 8),
        Container(padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: C.field, borderRadius: BorderRadius.circular(10)),
          // textInputAction.done: Enter логинит вместо вставки переноса строки (двойной вход гасит
          // внутренний гвард _loggingIn); при maxLines:2 done не мешает вставке многострочного ключа
          child: TextField(controller: _loginCtrl, maxLines: 2, style: mono(11, c: C.text), cursorColor: C.accent,
            textInputAction: TextInputAction.done, onSubmitted: (_) => _login(),
            decoration: InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero,
              hintText: tr('VPN-ключ (vless://…) или Код входа'), hintStyle: mono(12, c: C.muted)))),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _btn(tr('Войти'), kind: 1, icon: Icons.login, onTap: _loggingIn ? null : () => _login())),
          const SizedBox(width: 12),
          Expanded(child: _btn(tr('Ключ в боте'), kind: 1, icon: Icons.smart_toy, onTap: () => _open(kBot))),
        ]),
      ]));
    }
    final days = _daysLeft();
    final dleft = (days ?? 0).clamp(0, 100000).toInt();
    final total = _planTotalDays[subPlan] ?? 30;
    final ringFrac = total > 0 ? (dleft / total).clamp(0.0, 1.0) : 0.0;
    return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [_gIcon(Icons.workspace_premium), const SizedBox(width: 12), _kicker(tr('подписка')), const Spacer(),
        _subVisibleLoading
            ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: C.accent))
            : IconButton(
                onPressed: () => _refreshSub(),
                iconSize: 18,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                splashRadius: 22,
                tooltip: tr('Обновить'),
                icon: Icon(Icons.refresh, color: C.accent))]),
      const SizedBox(height: 16),
      Row(children: [
        // активная подписка без даты окончания → «—» с полным кольцом (а не обманчивые «0 дн.»)
        _ring(days == null ? '—' : '$dleft', days == null ? (subActive ? 1.0 : 0.0) : ringFrac),
        const SizedBox(width: 20),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_planLabel(subPlan), style: disp(20, w: FontWeight.w700, c: subActive ? C.accent : C.muted)),
          const SizedBox(height: 6),
          Row(children: [Icon(Icons.event, size: 14, color: C.muted), const SizedBox(width: 6),
            Text(
              days != null
                  ? (days > 0
                      ? (appLang == 'en' ? '$days ${days == 1 ? 'day' : 'days'} left' : 'осталось $days ${_pluralDays(days)}')
                      : tr('истекла'))
                  : (subActive ? tr('активна') : tr('не активна')),
              style: mono(13))]),
          const SizedBox(height: 4),
          Row(children: [Icon(Icons.devices, size: 14, color: C.muted), const SizedBox(width: 6),
            // Expanded: на узком экране строка про устройства вылезала за карточку и обрезалась
            Expanded(child: Text(appLang == 'en' ? '${devices.length} / $_limitStr devices' : '${devices.length} / $_limitStr устройств',
                style: mono(13), maxLines: 1, overflow: TextOverflow.ellipsis))]),
        ])),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        // «Продлить» больше не выкидывает наружу: нативный пейвол с тарифами внутри приложения
        Expanded(child: _btn(tr('Продлить'), kind: 0, icon: Icons.bolt, onTap: _openPaywall)),
        const SizedBox(width: 12),
        Expanded(child: _btn(tr('Обновить'), kind: 1, icon: Icons.refresh, onTap: () => _refreshSub())),
      ]),
    ]));
  }

  // ---------------- QR + SHARE ----------------
  // QR-код содержимого (ключ/код/реф-ссылка): диалог с крупным сканируемым QR. qr_flutter рисует
  // локально (без камеры/сети). Тёмный фон карточки → белая подложка под QR для контраста сканера.
  void _showQr(String data, String title, {String? hint}) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: C.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
        title: Text(title, style: disp(17, w: FontWeight.w700)),
        content: SizedBox(width: 300, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
            // белые модули на белом фоне не считаются — QR всегда тёмный на белом, вне зависимости от темы
            child: QrImageView(
              data: data,
              version: QrVersions.auto,
              size: 232,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF0C0A14)),
              dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF0C0A14)),
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),
          const SizedBox(height: 12),
          Text(hint ?? tr('Наведи камеру другого устройства'), textAlign: TextAlign.center, style: mono(11, c: C.muted)),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Закрыть'), style: mono(13, c: C.accent)))],
      ),
    );
  }

  // «Отправить на другое устройство»: нативный share-sheet (iOS/Android/macOS). Первой строкой —
  // deep-link bitaps://import?key=… (тап на устройстве с приложением → мгновенный импорт), второй —
  // сырой ключ для ручной вставки. На платформах без нативного шаринга (часть Win/Linux) share_plus
  // сам делает разумный фолбэк; дополнительно кладём в буфер, чтобы отправка не «проглотилась».
  Future<void> _shareKey() async {
    final deep = 'bitaps://import?key=${Uri.encodeComponent(keyStr)}';
    final text = appLang == 'en'
        ? 'Open in bitaps VPN:\n$deep\n\nOr paste this key manually:\n$keyStr'
        : 'Открыть в bitaps VPN:\n$deep\n\nИли вставь ключ вручную:\n$keyStr';
    try {
      // sharePositionOrigin обязателен для iPad-поповера; на десктопе игнорируется.
      final box = context.findRenderObject() as RenderBox?;
      final origin = box != null ? box.localToGlobal(Offset.zero) & box.size : null;
      await Share.share(text, subject: 'bitaps VPN', sharePositionOrigin: origin);
    } catch (e) {
      debugPrint('_shareKey failed: $e');
      // фолбэк: в буфер + честный тост «скопировано для отправки»
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) _toast(appLang == 'en' ? 'Copied for sharing' : 'Скопировано для отправки');
    }
  }

  // «Открыть в Happ»: отдаём ключ/подписку стороннему клиенту Happ его же deep-link'ом
  // happ://add/<ключ или адрес подписки КАК ЕСТЬ> — ровно так, как это делает кабинет на сайте.
  // Именно без base64: на base64 Happ открывался и отвечал «ссылка подписки не валидна» —
  // хуже молчания. Сайт этот баг уже починил (см. open.html), здесь он оставался.
  // Зачем это здесь: узлы «белого списка» (транспорт xhttp через CDN) наш движок пока не умеет,
  // а Happ умеет — так пользователь получает ВСЕ узлы подписки, не дожидаясь смены движка.
  // Happ не установлен → уводим на страницу с инструкцией и ссылками на магазины.
  Future<void> _openInHapp() async {
    try {
      final ok = await launchUrl(Uri.parse('happ://add/$keyStr'), mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (_) {/* приложения нет / схема не зарегистрирована — ниже фолбэк */}
    if (!mounted) return;
    _toast(appLang == 'en' ? 'Happ not found — opening the guide' : 'Happ не найден — открываю инструкцию');
    await _open('https://bitapsvpn.com/happ.html');
  }

  // Ключа ещё нет: пока человек не вошёл, keyStr держит заглушку-пример (kDemoKey). Показывать
  // её как «ключ доступа для роутера» нельзя — это ключ в никуда: скопировав его в Happ, человек
  // получает нерабочее подключение и решает, что сломан сервис. Поэтому у гостя вместо строки
  // ключа — объяснение, а кнопки, раздающие ключ наружу (копировать, QR, поделиться, Happ), скрыты.
  Widget _keyCard() {
    final hasKey = keyStr.isNotEmpty && keyStr != kDemoKey;
    return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [_gIcon(Icons.qr_code_2), const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _kicker(tr('ключ доступа')), const SizedBox(height: 3),
            Text(hasKey
                    ? (loggedIn ? tr('твой ключ из аккаунта') : tr('для роутера и ручной настройки'))
                    : tr('появится после входа'),
                style: mono(11))])),
          // Показать QR ключа — быстрый перенос на телефон/роутер сканером
          if (hasKey) IconButton(
            onPressed: () => _showQr(keyStr, tr('QR ключа'),
                hint: tr('Отсканируй в VPN-клиенте или другом устройстве')),
            iconSize: 22, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40), splashRadius: 22,
            tooltip: tr('Показать QR'), icon: Icon(Icons.qr_code_2, color: C.accent))]),
        const SizedBox(height: 12),
        Container(padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: C.field, borderRadius: BorderRadius.circular(10)),
          // SelectableText: выделение мышью само доскролливает до хвоста длинного ключа и даёт
          // контекстное меню копирования (обычный Text в гориз. скролле хвост мышью не достать)
          child: hasKey
              ? SingleChildScrollView(scrollDirection: Axis.horizontal,
                  child: SelectableText(keyStr, style: mono(11, c: C.text), maxLines: 1))
              : Text(tr('Войди по ключу или через Telegram — ключ подписки появится здесь'),
                  style: mono(11, c: C.muted))),
        const SizedBox(height: 12),
        Row(children: [
          if (hasKey) ...[
            Expanded(child: _btn(tr('Скопировать'), kind: 1, icon: Icons.copy, onTap: () => _copy(keyStr, tr('Ключ'), secret: true))),
            const SizedBox(width: 12),
          ],
          Expanded(child: loggedIn
              ? _btn(tr('Обновить'), kind: 2, icon: Icons.refresh, onTap: () => _refreshSub())
              : _btn(tr('Вставить'), kind: 2, icon: Icons.content_paste, onTap: _importKey)),
        ]),
        if (hasKey) ...[
          const SizedBox(height: 10),
          // «Отправить на другое устройство» — deep-link + сырой ключ через share-sheet
          _btn(tr('Отправить на другое устройство'), kind: 2, icon: Icons.ios_share, onTap: _shareKey),
          const SizedBox(height: 10),
          // Happ понимает ВСЕ узлы подписки, включая «белый список» (xhttp), — даём быстрый импорт
          _btn(tr('Открыть в Happ'), kind: 2, icon: Icons.open_in_new, onTap: _openInHapp),
        ],
        if (loggedIn && loginSecret != null) ...[
          const SizedBox(height: 12),
          _divider(), // единый разделитель как в остальном UI (было голое Divider(...))
          const SizedBox(height: 10),
          Row(children: [_gIcon(Icons.lock_outline), const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _kicker(tr('код входа')), const SizedBox(height: 3),
              Text(tr('для входа в приложение — не вставляй в VPN-клиенты'), style: mono(11))])),
            // QR кода входа = deep-link bitaps://login?secret=… — вход на другом устройстве сканером
            IconButton(
              onPressed: () => _showQr('bitaps://login?secret=${Uri.encodeComponent(loginSecret!)}', tr('QR кода входа'),
                  hint: tr('Отсканируй в приложении bitaps на другом устройстве')),
              iconSize: 22, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40), splashRadius: 22,
              tooltip: tr('Показать QR'), icon: Icon(Icons.qr_code_2, color: C.accent))]),
          const SizedBox(height: 10),
          Container(padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: C.field, borderRadius: BorderRadius.circular(10)),
            child: Text(loginSecret!, style: mono(11, c: C.text), maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _btn(tr('Скопировать'), kind: 1, icon: Icons.copy, onTap: () => _copy(loginSecret!, tr('Код входа'), secret: true))),
            const SizedBox(width: 12),
            Expanded(child: _btn(tr('Сменить'), kind: 2, icon: Icons.refresh, onTap: _rotating ? null : _rotateSecret)),
          ]),
        ],
      ]));
  }

  Widget _devicesCard() => _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [_gIcon(Icons.devices), const SizedBox(width: 12),
          // Expanded вместо пары «текст + Spacer»: заголовок карточки не влезал рядом с иконкой
          // обновления и уезжал под неё
          Expanded(child: _kicker(appLang == 'en' ? 'devices · ${devices.length}/$_limitStr' : 'устройства · ${devices.length}/$_limitStr')),
          _subVisibleLoading
              ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: C.accent))
              : IconButton(
                  onPressed: () => _refreshSub(),
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                  splashRadius: 22,
                  tooltip: tr('Обновить'),
                  icon: Icon(Icons.refresh, color: C.accent))]),
        const SizedBox(height: 8),
        if (devicesUnknown)
          // хаб молчал (devices_unknown): это НЕ «устройств нет» — кэш мог и не обновиться
          Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Column(children: [
            Icon(Icons.cloud_off, size: 30, color: C.muted),
            const SizedBox(height: 8),
            Text(tr('Не удалось получить список устройств.\nПопробуй обновить.'), textAlign: TextAlign.center, style: mono(12)),
          ]))
        else if (devices.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Column(children: [
            Icon(Icons.devices_other, size: 30, color: C.muted),
            const SizedBox(height: 8),
            Text(tr('Пока нет устройств.\nПодключись с устройства — оно появится здесь.'), textAlign: TextAlign.center, style: mono(12)),
          ]))
        else
          for (final d in devices) _deviceRow(d),
      ]));

  Widget _deviceRow(Map<String, dynamic> d) {
    // name на бэкенде NOT NULL, но пустая строка '' допустима (?? ловит только null) → пустая
    // строка в списке; toString() страхует от нестрокового значения (иначе as String? → TypeError).
    final raw = d['name']?.toString().trim() ?? '';
    final name = raw.isEmpty ? tr('Устройство') : raw;
    final id = d['id']?.toString();
    return Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Row(children: [
      Icon(Icons.smartphone, size: 18, color: C.muted),
      const SizedBox(width: 10),
      Expanded(child: Text(name, style: disp(14, w: FontWeight.w600), overflow: TextOverflow.ellipsis)),
      // Тап-таргет удаления ≥40px (было 19px). Гасим во время ЯВНОГО обновления (_subVisibleLoading):
      // иначе подтверждённое удаление молча упёрлось бы в re-entrancy-гвард _refreshSub и потерялось.
      // Тихий фоновый рефреш корзину не гасит — иначе на офлайн-старте она была бы мертва 20с.
      IconButton(
        onPressed: (id == null || _subVisibleLoading) ? null : () => _confirmDelDevice(id, name),
        iconSize: 19,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        splashRadius: 22,
        tooltip: tr('Удалить'),
        icon: Icon(Icons.delete_outline, color: C.danger)),
    ]));
  }

  // ---------------- «// статистика» ----------------
  // Честные факты аккаунта из app-sub (member_since / total_paid_days / referral_count /
  // token_balance / renewal_streak). Цифры — моноширинные; null (данные ещё не пришли) → «—».
  // Никаких трафик-цифр: туннель в демо, выдумывать нечего.
  Widget _statsCard() {
    String since = '—';
    if (statMemberSince != null) {
      final t = DateTime.tryParse(statMemberSince!);
      if (t != null) {
        final loc = t.toLocal();
        since = '${loc.day.toString().padLeft(2, '0')}.${loc.month.toString().padLeft(2, '0')}.${loc.year}';
      }
    }
    Widget cell(String val, String label) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(val, style: mono(17, c: C.text, w: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(label, style: mono(10.5, c: C.muted)),
        ]));
    return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [_gIcon(Icons.query_stats), const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _kicker(tr('статистика')), const SizedBox(height: 3),
          Text(tr('твоя история с bitaps'), style: mono(11))]))]),
      const SizedBox(height: 14),
      Row(children: [
        cell(since, tr('с нами с')),
        cell(statPaidDays != null ? '$statPaidDays' : '—', tr('оплачено дней')),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        cell(statRefs != null ? '$statRefs' : '—', tr('друзей приглашено')),
        cell(statTokens != null ? '$statTokens 🪙' : '—', tr('токены')),
      ]),
      const SizedBox(height: 12),
      _divider(),
      const SizedBox(height: 8),
      // стрик продлений + мягкая продажа раннего продления (реальная механика +3/+5/+7 дней)
      Row(children: [
        Icon(Icons.local_fire_department, size: 16, color: subStreak > 0 ? C.accent : C.muted),
        const SizedBox(width: 8),
        Expanded(child: Text(
          subActive && subNextBonus > 0
              ? (appLang == 'en'
                  ? 'Renewal streak: $subStreak · renew before expiry for +$subNextBonus bonus days'
                  : 'Стрик продлений: $subStreak · продли до истечения — +$subNextBonus ${_pluralDays(subNextBonus)} бонусом')
              : (appLang == 'en' ? 'Renewal streak: $subStreak' : 'Стрик продлений: $subStreak'),
          style: mono(11.5, c: C.muted))),
      ]),
    ]));
  }

  void _confirmDelDevice(String id, String name) {
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: C.bg2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: C.line)),
      title: Text(tr('Удалить устройство?'), style: disp(18, w: FontWeight.w700)),
      content: Text(appLang == 'en' ? '"$name" will be removed from the subscription.' : '«$name» будет удалено из подписки.', style: mono(13, c: C.muted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Отмена'), style: mono(13, c: C.muted))),
        TextButton(onPressed: () { Navigator.pop(context); _refreshSub(del: id); }, child: Text(tr('Удалить'), style: mono(13, c: C.danger))),
      ],
    ));
  }

  Widget _faqRow(Faq f) => Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 12),
          iconColor: C.accent,
          collapsedIconColor: C.muted,
          title: Text(tr(f.q), style: disp(14, w: FontWeight.w600)),
          children: [Align(alignment: Alignment.centerLeft, child: Text(tr(f.a), style: mono(13)))],
        ),
      );
}
