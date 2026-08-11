part of 'main.dart';

// ============================ I18N (RU / EN) ============================
// Лёгкая локализация без внешних пакетов. Весь видимый пользователю русский текст
// проходит через tr(): в режиме 'en' подменяется на английский из _kEn, иначе остаётся русским.
// Строки с интерполяцией ($days, ${s.city} и т.п.) tr() не покрывает — они локализуются
// НА МЕСТЕ выражением `appLang == 'en' ? '<en>' : '<ru>'` (см. вызовы в других part-файлах).
//
// appLang меняется в Настройках (RU/EN) и сохраняется в prefs (ключ 'lang'); при первом
// запуске берётся из системной локали (см. _load в main.dart). Смена языка вызывает setState —
// весь UI перечитывает tr() и перерисовывается на лету.
String appLang = 'ru';

// kCountryEn — вторым словарём, а не строками внутри _kEn: названия стран приходят с сервиса
// выдачи (метка узла подписки), их набор меняется при добавлении ноды и не связан с текстами
// интерфейса. Порядок поиска важен: _kEn может переопределить страну (например «🇷🇺 Россия»
// целиком с флагом), а kCountryEn закрывает всё остальное.
String tr(String ru) => appLang == 'en' ? (_kEn[ru] ?? kCountryEn[ru] ?? ru) : ru;

/// Названия стран для списка серверов: узлы приходят из подписки метками вида «🇮🇸 Исландия»
/// и «🛡️ Румыния · LTE», то есть по-русски всегда. Без этой таблицы английский интерфейс
/// показывал «Finland» рядом с «Исландия», «Гонконг» и «Румыния» — переведено было ровно то,
/// что случайно осталось в словаре от старого выдуманного списка локаций.
///
/// Держим с запасом — все страны, куда реально ставят выходные узлы, а не только текущие 7:
/// новая нода не должна требовать правки приложения, иначе смешанный язык вернётся молча.
/// Чего в таблице нет — показываем по-русски (честный откат, ничего не ломается).
const Map<String, String> kCountryEn = {
  // Европа
  'Австрия': 'Austria', 'Албания': 'Albania', 'Белоруссия': 'Belarus', 'Беларусь': 'Belarus',
  'Бельгия': 'Belgium', 'Болгария': 'Bulgaria', 'Босния и Герцеговина': 'Bosnia and Herzegovina',
  'Великобритания': 'United Kingdom', 'Венгрия': 'Hungary', 'Германия': 'Germany',
  'Гибралтар': 'Gibraltar', 'Греция': 'Greece', 'Дания': 'Denmark', 'Ирландия': 'Ireland',
  'Исландия': 'Iceland', 'Испания': 'Spain', 'Италия': 'Italy', 'Кипр': 'Cyprus',
  'Латвия': 'Latvia', 'Литва': 'Lithuania', 'Лихтенштейн': 'Liechtenstein',
  'Люксембург': 'Luxembourg', 'Мальта': 'Malta', 'Молдавия': 'Moldova', 'Молдова': 'Moldova',
  'Монако': 'Monaco', 'Нидерланды': 'Netherlands', 'Норвегия': 'Norway', 'Польша': 'Poland',
  'Португалия': 'Portugal', 'Румыния': 'Romania', 'Северная Македония': 'North Macedonia',
  'Сербия': 'Serbia', 'Словакия': 'Slovakia', 'Словения': 'Slovenia', 'Украина': 'Ukraine',
  'Финляндия': 'Finland', 'Франция': 'France', 'Хорватия': 'Croatia', 'Черногория': 'Montenegro',
  'Чехия': 'Czechia', 'Швейцария': 'Switzerland', 'Швеция': 'Sweden', 'Эстония': 'Estonia',
  // Азия и Ближний Восток
  'Азербайджан': 'Azerbaijan', 'Армения': 'Armenia', 'Бахрейн': 'Bahrain', 'Вьетнам': 'Vietnam',
  'Грузия': 'Georgia', 'Израиль': 'Israel', 'Индия': 'India', 'Индонезия': 'Indonesia',
  'Иордания': 'Jordan', 'Казахстан': 'Kazakhstan', 'Катар': 'Qatar', 'Киргизия': 'Kyrgyzstan',
  'Китай': 'China', 'Гонконг': 'Hong Kong', 'Макао': 'Macao', 'Тайвань': 'Taiwan',
  'Малайзия': 'Malaysia', 'ОАЭ': 'UAE', 'Оман': 'Oman', 'Пакистан': 'Pakistan',
  'Саудовская Аравия': 'Saudi Arabia', 'Сингапур': 'Singapore', 'Таиланд': 'Thailand',
  'Турция': 'Turkey', 'Узбекистан': 'Uzbekistan', 'Филиппины': 'Philippines',
  'Южная Корея': 'South Korea', 'Корея': 'South Korea', 'Япония': 'Japan',
  // Америка, Африка, Океания
  'Австралия': 'Australia', 'Аргентина': 'Argentina', 'Бразилия': 'Brazil', 'Канада': 'Canada',
  'Колумбия': 'Colombia', 'Мексика': 'Mexico', 'Новая Зеландия': 'New Zealand',
  'Панама': 'Panama', 'США': 'United States', 'Чили': 'Chile',
  'Египет': 'Egypt', 'Кения': 'Kenya', 'Марокко': 'Morocco', 'Нигерия': 'Nigeria',
  'ЮАР': 'South Africa',
  // Россия оставлена отдельно в _kEn (там строка с флагом целиком) — здесь без флага
  'Россия': 'Russia',
};

const Map<String, String> _kEn = {
  // ---- main.dart (диалоги/тосты/навигация) ----
  'Не сервер bitaps': 'Not a bitaps server',
  'Отмена': 'Cancel',
  'Импортировать': 'Import',
  'Нет связи с сервером — проверь интернет.': 'No connection to server — check your internet.',
  'Вышли из аккаунта': 'Signed out',
  'Выйти?': 'Sign out?',
  'Выйдешь из аккаунта на этом устройстве. Подключение отключится, персональные настройки сохранятся.':
      "You'll sign out on this device. The connection will stop, your personal settings stay.",
  'Выйти': 'Sign out',
  'Ок': 'OK',
  'Отключись, чтобы сменить сервер': 'Disconnect to switch server',
  'Отключись, чтобы сменить режим': 'Disconnect to switch mode',
  'Не удалось открыть ссылку': "Couldn't open the link",
  'Главная': 'Home',
  'Серверы': 'Servers',
  'Кабинет': 'Account',
  'Настройки': 'Settings',

  // ---- connection.dart ----
  'Нужен рабочий VPN-ключ': 'Need a working VPN key',
  'В подписке нет доступных серверов': 'No servers available in your subscription',
  'Узлы подписки отклонены: чужие адреса': 'Subscription servers rejected: foreign addresses',
  'Узлы подписки не поддерживаются этой сборкой': 'This build cannot use the subscription servers',
  'На этой системе туннель ещё не поддержан': 'This system cannot run the tunnel yet',
  'подписка bitaps': 'bitaps subscription',
  'Открыть в Happ': 'Open in Happ',
  'Соединение разорвано': 'Connection dropped',

  // ---- widgets.dart ----
  'защищено': 'protected',
  'не защищено': 'unprotected',
  'дн.': 'days',

  // ---- api.dart (сеть, вход, поддержка) ----
  'Минутку…': 'One moment…',
  'Сначала войди': 'Sign in first',
  'Меняю код…': 'Changing code…',
  'Сессия истекла — войди снова': 'Session expired — sign in again',
  'Код входа обновлён ✓': 'Login code updated ✓',
  'Не удалось сменить код': "Couldn't change the code",
  'Вставь VPN-ключ или Код входа': 'Paste your VPN key or login code',
  'Вход по VPN-ключу отключён. Вставь «Код входа» (UUID) из бота или письма.':
      'Signing in with a VPN key is disabled. Paste your login code (UUID) from the bot or email.',
  'Вставь «Код входа» (UUID) — без пробелов': 'Paste your login code (UUID) — no spaces',
  'Вхожу…': 'Signing in…',
  'Этот ключ не подошёл. Возьми актуальный ключ в боте.': "This key didn't work. Get a fresh key from the bot.",
  'Этот код не подошёл. Возьми актуальный в боте (/start → Код входа).': "This code didn't work. Get a fresh one in the bot (/start → Login code).",
  'Слишком много попыток. Подожди минуту и попробуй снова.': 'Too many attempts. Wait a minute and try again.',
  'Вход выполнен ✓': 'Signed in ✓',
  'Ключ не найден. Возьми актуальный ключ в боте.': 'Key not found. Get a fresh key from the bot.',
  'Код не найден. Возьми актуальный в боте (/start → Код входа).': 'Code not found. Get a fresh one in the bot (/start → Login code).',
  'Не удалось начать вход, попробуй ещё раз': "Couldn't start sign-in, try again",
  'Подтверди вход в Telegram': 'Confirm sign-in in Telegram',
  'Открылся бот — нажми «Запустить», затем «✅ Да, это я». Войду сам, как подтвердишь.':
      'The bot opened — tap "Start", then "✅ Yes, it\'s me". I\'ll sign you in once you confirm.',
  'Не дождался подтверждения. Открой бота и нажми «Запустить».':
      "Didn't get confirmation. Open the bot and tap \"Start\".",
  'Не удалось войти': "Couldn't sign in",
  'Закрыть': 'Close',
  'Открыть бота': 'Open the bot',
  'Сначала войди по ключу': 'Sign in with your key first',
  'Сначала войди или импортируй ключ': 'Sign in or import a key first',
  'Удаляю устройство…': 'Removing device…',
  'Обновляю…': 'Refreshing…',
  'Уже обновляю — секунду': 'Still refreshing — one sec',
  'Идёт обновление — удаление не выполнено, повтори через секунду': 'Refresh in progress — removal not done, retry in a second',
  'Уже выполняю — секунду': 'Still running — one sec',
  'Чтобы удалить устройство, нужен «Код входа». Открой его в боте (/start → Код входа) и войди по нему.':
      'To remove a device, you need your login code. Get it in the bot (/start → Login code) and sign in with it.',
  'Не удалось подтвердить «Код входа» для удаления.': "Couldn't confirm the login code for removal.",
  'Устройство удалено ✓': 'Device removed ✓',
  'Обновлено ✓': 'Updated ✓',
  'Не удалось обновить': "Couldn't refresh",
  'Сначала напиши сообщение': 'Write a message first',
  'Укажи, куда ответить — почта или @ник': 'Tell us where to reply — email or @handle',
  'Отправляю…': 'Sending…',
  'Пользователь приложения': 'App user',
  'Отправлено ✓ — ответим на указанный контакт': 'Sent ✓ — we\'ll reply to the contact you gave',
  'Проверка утечек': 'Leak check',
  'IP не получен': "Couldn't get IP",
  'Тест скорости': 'Speed test',

  // ---- home.dart ----
  'Доступно обновление': 'Update available',
  'Скачать обновление': 'Download the update',
  'Позже': 'Later',
  'Больше не предлагать эту версию': "Don't offer this version again",
  'Переподключение…': 'Reconnecting…',
  'Отключено': 'Disconnected',
  'Подключение…': 'Connecting…',
  'Подключено': 'Connected',
  'под защитой': "you're protected",
  'под защитой — браузеры и приложения с системным прокси':
      "protected — browsers and apps that use the system proxy",
  'Демо-режим': 'Demo mode',
  'демо — без реального туннеля': 'demo — no real tunnel',
  'демо': 'demo',
  'нажми на кнопку': 'tap the button',
  'устанавливаем соединение…': 'establishing connection…',
  'Подключиться': 'Connect',
  'Скорость появится после подключения': 'Speed will appear once connected',
  'Режим подбирает сервер: Авто/Игры — минимальный отклик, Стрим — наименьшая нагрузка, Прив. — самый быстрый узел.':
      'Mode picks the server: Auto/Games — lowest latency, Stream — lowest load, Private — the fastest node.',
  'сервер не выбран': 'no server selected',
  'появится вместе с подпиской': 'appears with your subscription',
  'сменить': 'change',
  'IP скрыт': 'IP hidden',
  'Демо-режим — скорость и IP показаны для примера': 'Demo mode — speed and IP are sample values',
  'Отключить': 'Disconnect',
  // карточка «почему не подключилось» + её кнопки-действия
  'Подключение не выполнено': 'Connection failed',
  'Скачать приложение': 'Download the app',
  'Обновить подписку': 'Refresh subscription',
  'Написать в поддержку': 'Message support',
  'Подключаться к лучшему серверу': 'Connect to the best server',
  'при подключении сам возьму оптимальный под режим': "auto-picks the optimal server for your mode",
  'выключено — сервер выбираешь ты': 'off — you pick the server',
  // карточка килл-свитча (fail-closed после неожиданного обрыва)
  'Трафик заблокирован': 'Traffic blocked',
  'VPN отвалился — трафик заблокирован': 'VPN dropped — traffic is blocked',
  'VPN отвалился — килл-свитч не пускает трафик напрямую': 'VPN dropped — the kill switch keeps traffic from going direct',
  'Килл-свитч держит прокси включённым: интернет не пойдёт мимо туннеля. Сними блокировку или подключись снова.':
      'The kill switch keeps the proxy on: no traffic goes direct. Unblock it or reconnect.',
  'Снять блокировку': 'Unblock',
  'Не удалось снять блокировку — ответь на системный запрос пароля':
      'Could not unblock — answer the system password prompt',

  // ---- servers.dart ----
  'Пинг серверов': 'Ping servers',
  'замеряю отклик…': 'measuring latency…',
  'замерить отклик доступных серверов': 'measure latency of available servers',
  'Пинг обновлён ✓': 'Ping updated ✓',
  '⭐ избранное': '⭐ favorites',
  'избранное': 'favorites',
  '🇷🇺 Россия': '🇷🇺 Russia',
  '🌍 зарубежные · скоро': '🌍 international · soon',
  'прямые серверы': 'direct servers',
  'устойчивый · CDN': 'resilient · CDN',
  'Войди в аккаунт — здесь появятся твои серверы': 'Sign in — your servers will appear here',
  // Названия локаций серверов. Раньше здесь лежала горстка строк из выдуманного списка
  // (Москва/СПб/Екатеринбург), а реальные узлы приходят из подписки — и в английском интерфейсе
  // список выглядел так: «Finland» переведена, а «Исландия», «Гонконг», «Румыния» остались
  // по-русски. Названия стран вынесены в kCountryEn (ниже) и подмешиваются в этот словарь: одна
  // таблица на все страны, куда мы можем поставить узел, вместо ручного добавления по одной.
  'Москва': 'Moscow',
  'Санкт-Петербург': 'Saint Petersburg',
  'Екатеринбург': 'Yekaterinburg',
  'Амстердам': 'Amsterdam',
  'Франкфурт': 'Frankfurt',
  'Хельсинки': 'Helsinki',
  'Стамбул': 'Istanbul',
  'быстрый отклик': 'low latency',
  'средний отклик': 'medium latency',
  'медленный отклик': 'high latency',
  'отклик не замерен': 'latency not measured',
  // проверка узлов «по-настоящему»: не TCP до адреса, а прошёл ли трафик сквозь туннель
  'Проверить серверы': 'Check the servers',
  'проверяю, где идёт трафик…': 'checking which ones pass traffic…',
  'проверить, через какие серверы реально идёт трафик': 'find out which servers actually pass traffic',
  'через этот сервер трафик не идёт': 'no traffic gets through this server',
  'не проверен': 'not checked yet',
  'замер сквозь активный туннель': 'measure through the active tunnel',
  'не работает': 'not working',
  'Выбрать сервер': 'Pick a server',
  'Через этот сервер сейчас не идёт трафик — выбери другой или включи «лучший сервер»':
      'This server is not passing traffic right now — pick another one or turn on "Best server"',
  'Ни один сервер не ответил — проверь интернет': 'No server answered — check your internet',
  'Прямая нода недоступна в этой сети — подключил через 🛡️':
      'The direct node is unreachable on this network — connected via a 🛡️ relay',
  'Соединение потеряно': 'Connection lost',
  'Соединение потеряно — переподключаюсь…': 'Connection lost — reconnecting…',
  'нажми на сервер — переключусь без разрыва': 'tap a server — I will switch without dropping the VPN',
  'только что': 'just now',
  'данные недоступны': 'data unavailable',
  'скоро': 'soon',
  'прямой узел': 'direct node',
  'через CDN': 'via CDN',

  // ---- bbox.dart (экран B-box: товар, предзаказ, «поторопить сборку») ----
  'Назад': 'Back',
  'устройство для дома': 'a device for your home',
  'VPN для всего дома': 'VPN for the whole home',
  'Коробка становится вашим роутером: защищён каждый экран в доме — телевизор, приставка, колонка, ноутбук. Ничего не настраивая на каждом устройстве.':
      'The box becomes your router: every screen at home is protected — TV, console, speaker, laptop. Nothing to set up on each device.',
  'Сейчас идёт сборка и закупка материалов. Предзаказ ничего не списывает — это место в очереди и фиксация цены.':
      'Assembly and sourcing are under way. A pre-order charges you nothing — it holds your place in the queue and locks the price.',
  'что внутри': 'what is inside',
  'Точка доступа': 'Access point',
  'Раздаёт свой Wi-Fi: подключился — уже под защитой': 'It runs its own Wi-Fi: connect and you are already protected',
  'Наш туннель внутри': 'Our tunnel inside',
  'Те же узлы, что и в приложении — стабильные в любых сетях': 'The same nodes as in the app — stable on any network',
  'Сколько угодно устройств': 'As many devices as you like',
  'Телевизор, приставка, колонка — лимит подписки не тратится': 'TV, console, speaker — your subscription limit is not spent',
  'Включил и забыл': 'Plug it in and forget it',
  'Обновляется сама, настройка — один раз с телефона': 'Updates itself; you set it up once from your phone',
  'цена': 'price',
  'Устройство покупается один раз. Подписка на VPN оплачивается отдельно, как обычно.':
      'The device is a one-time purchase. The VPN subscription is paid separately, as usual.',
  'Предзаказ принят': 'Pre-order accepted',
  'предзаказ': 'pre-order',
  'Имя': 'Name',
  'Телефон': 'Phone',
  'Город': 'City',
  'Адрес доставки': 'Delivery address',
  'Индекс': 'Postcode',
  'Комментарий (не обязательно)': 'Comment (optional)',
  'Оформить предзаказ': 'Place a pre-order',
  'Предоплаты нет. Заявка уходит менеджеру, он свяжется по указанному телефону.':
      'No prepayment. The request goes to a manager who will call the number you gave.',
  'поторопить сборку': 'speed up the build',
  'Чем больше подтверждённых предзаказов, тем крупнее партия материалов и тем быстрее сборка. Напиши, если готов забрать раньше или можешь помочь с комплектующими.':
      'The more confirmed pre-orders, the bigger the materials batch and the faster the build. Write to us if you can take yours earlier or can help with parts.',
  'Что предлагаешь?': 'What do you suggest?',
  'Напиши, что предлагаешь': 'Tell us what you suggest',

  // ---- account.dart (тарифы/подписка/ключ/устройства) ----
  '1 месяц': '1 month',
  '3 месяца': '3 months',
  '6 месяцев': '6 months',
  '12 месяцев': '12 months',
  'Пробный период': 'Trial period',
  '1 МЕС': '1 MO',
  '3 МЕС': '3 MO',
  '6 МЕС': '6 MO',
  '1 ГОД': '1 YR',
  'ТРИАЛ': 'TRIAL',
  'появится после входа': 'appears after you sign in',
  'Войди по ключу или через Telegram — ключ подписки появится здесь':
      'Sign in with your key or via Telegram — your subscription key will appear here',
  'В буфере нет VPN-ключа': 'No VPN key in the clipboard',
  'неизвестный хост': 'unknown host',
  'Ключ заменён ✓': 'Key replaced ✓',
  'Подписка истекла': 'Subscription expired',
  'Подписка истекает': 'Subscription expiring',
  'Продли, чтобы вернуть доступ': 'Renew to restore access',
  'Продлить →': 'Renew →',
  'пригласи друзей': 'invite friends',
  'Приглашай — получай бонусные дни': 'Invite friends — earn bonus days',
  '▸ +14 дней и +100 🪙 за каждого друга, кто оформит первую подписку\n▸ начисляем автоматически':
      '▸ +14 days and +100 🪙 for every friend who buys their first subscription\n▸ added automatically',
  'Поделиться ссылкой': 'Share link',
  'Войди, чтобы получить свою реферальную ссылку': 'Sign in to get your referral link',
  'Рефералы — через нашего Telegram-бота': 'Referrals work through our Telegram bot',
  'Реферальная ссылка': 'Referral link',
  'B-box — VPN для всего дома': 'B-box — VPN for the whole home',
  'устройство для дома · 15 000 ₽': 'home device · 15 000 ₽',
  'поддержка': 'support',
  'Почта или @ник — куда ответить': 'Email or @handle — where to reply',
  'Опиши проблему…': 'Describe the problem…',
  'Отправить': 'Send',
  'или напиши @bitapssupport': 'or message @bitapssupport',
  'частые вопросы': 'faq',
  'Вход не выполнен': 'Not signed in',
  'Вход выполнен': 'Signed in',
  'Войди через Telegram, чтобы активировать подписку': 'Sign in with Telegram to activate your subscription',
  'Активна': 'Active',
  'Не активна': 'Inactive',
  'Гость': 'Guest',
  'Нет подписки': 'No subscription',
  'вход': 'sign in',
  'Войди через Telegram — приложение само подхватит твою подписку и ключ. Без ручного копирования.':
      'Sign in with Telegram — the app pulls in your subscription and key automatically. No manual copying.',
  'Войти через Telegram': 'Sign in with Telegram',
  'или вставь VPN-ключ / Код входа:': 'or paste your VPN key / login code:',
  'VPN-ключ (vless://…) или Код входа': 'VPN key (vless://…) or login code',
  'Войти': 'Sign in',
  'Ключ в боте': 'Key in the bot',
  'подписка': 'subscription',
  'истекла': 'expired',
  'активна': 'active',
  'не активна': 'inactive',
  'Продлить': 'Renew',
  'Обновить': 'Refresh',
  'ключ доступа': 'access key',
  'твой ключ из аккаунта': 'the key from your account',
  'для роутера и ручной настройки': 'for routers and manual setup',
  'Скопировать': 'Copy',
  'Вставить': 'Paste',
  'Ключ': 'Key',
  'код входа': 'login code',
  'для входа в приложение — не вставляй в VPN-клиенты': "for signing into the app — don't paste into VPN clients",
  'Код входа': 'Login code',
  'Сменить': 'Change',
  'Пока нет устройств.\nПодключись с устройства — оно появится здесь.':
      "No devices yet.\nConnect from a device — it will show up here.",
  'Не удалось получить список устройств.\nПопробуй обновить.':
      "Couldn't fetch the device list.\nTry refreshing.",
  'Устройство': 'Device',
  'Удалить устройство?': 'Remove device?',
  'Удалить': 'Remove',

  // ---- settings.dart ----
  'Тёмная': 'Dark',
  'Светлая': 'Light',
  'Системная': 'System',
  'Статистика': 'Statistics',
  'Свой конфиг': 'Custom config',
  'Свой конфиг ✓': 'Custom config ✓',
  'Вставь ключ vless://, trojan://, ss://…': 'Paste a vless://, trojan://, ss://… key',
  'Сохранить': 'Save',
  'Конфиг очищен': 'Config cleared',
  'персонализация': 'personalization',
  'Цвет акцента': 'Accent color',
  'Кнопка подключения': 'Connect button',
  'Тема': 'Theme',
  'Язык': 'Language',
  'безопасность': 'security',
  'Блокировка входа': 'App lock',
  'Только экран: от доступа к устройству не защищает': 'Screen only — it does not protect against device access',
  'Обрыв соединения': 'Connection drop',
  'Уведомлять, если VPN отвалился': 'Notify if the VPN drops',
  'Килл-свитч': 'Kill switch',
  'Автопереподключение': 'Auto-reconnect',
  'Сам подключусь снова, если VPN оборвётся': 'Reconnects on its own if the VPN drops',
  'Килл-свитч на Android': 'Kill switch on Android',
  'Понятно': 'Got it',
  'Напомнить за пару дней': 'Remind me a couple of days ahead',
  'Лимит трафика': 'Traffic limit',
  'Сигнал при расходе от 5 ГБ за сессию': 'Alert at 5 GB+ used per session',
  'Авто-подключение': 'Auto-connect',
  'Подключаться сразу при запуске': 'Connect right at startup',
  'Показать интерфейс без реального туннеля': 'Show the interface without a real tunnel',
  'инструменты': 'tools',
  'подключение': 'connection',
  'Авто': 'Auto',
  'Протокол': 'Protocol',
  'подбирается автоматически': 'auto-detected',
  'Протокол подбирается автоматически под твой ключ. Настраивать ничего не нужно.':
      'The protocol is chosen automatically from your key. Nothing to configure.',

  // ---- modeLabels (home) ----
  'Стрим': 'Stream',
  'Игры': 'Games',
  'Прив.': 'Private',

  // ---- btnStyleNames (settings) ----
  'Шестерёнка': 'Gear',
  'Кольцо': 'Ring',
  'Орб': 'Orb',
  'Пульс': 'Pulse',

  // ---- lock.dart ----
  'bitaps заблокирован': 'bitaps locked',
  'Введи PIN, чтобы продолжить': 'Enter your PIN to continue',
  'Введите PIN': 'Enter PIN', // Semantics-метка PIN-поля (скринридер)
  'Разблокировать': 'Unlock',
  'Не помню PIN — сбросить': 'Forgot PIN — reset lock',
  'Сбросить PIN?': 'Reset PIN?',
  'Блокировка отключится, но ты останешься в аккаунте. PIN защищает только экран: сбросить его может любой, у кого есть доступ к этому устройству.':
      "The lock turns off, but you stay signed in. The PIN protects only the screen: anyone with access to this device can reset it.",
  'Сбросить': 'Reset',
  'Неверный PIN': 'Wrong PIN',
  'Блокировка сброшена': 'Lock reset',
  'Задай PIN для входа': 'Set a PIN to unlock',
  'PIN (4–8 цифр)': 'PIN (4–8 digits)',
  'Повтори PIN': 'Repeat PIN',
  'Включить': 'Enable',
  'PIN — минимум 4 цифры': 'PIN must be at least 4 digits',
  'PIN не совпадает': "PINs don't match",

  // ---- onboarding.dart ----
  'Пропустить': 'Skip',
  'Далее': 'Next',
  'что такое bitaps': 'what is bitaps',
  'VPN по одному ключу': 'VPN with a single key',
  'Подписка живёт в Telegram-боте, а этот клиент — её пульт: ключ, устройства и кабинет в одном окне.':
      'Your subscription lives in our Telegram bot — this client is its remote: key, devices and account in one window.',
  'Личный VPN-ключ': 'Personal VPN key',
  'один ключ на подписку — доп. устройства докупаются отдельно':
      'one key per subscription — extra devices are bought separately',
  'Все платформы': 'All platforms',
  'Windows, macOS, Linux, Android — одно приложение': 'Windows, macOS, Linux, Android — one app',
  'Оплата как удобно': 'Pay your way',
  'Telegram Stars, СБП или крипта — в пару тапов': 'Telegram Stars, SBP or crypto — a couple of taps',
  'три способа входа': 'three ways to sign in',
  'Входи как удобно': 'Sign in your way',
  'Через Telegram': 'With Telegram',
  'бот сам подтвердит вход — без ручного копирования': 'the bot confirms sign-in for you — no manual copying',
  'По VPN-ключу': 'With your VPN key',
  'вставь свой ключ (vless://…) — это и есть вход в аккаунт': 'paste your key (vless://…) — that is your account login',
  'По Коду входа': 'With a login code',
  'короткий код из бота — если ключ не под рукой': 'a short code from the bot — when the key is not at hand',
  'Всё это — на вкладке «Кабинет».': 'All of this lives in the "Account" tab.',
  'Настоящий туннель': 'A real tunnel',
  'Туннель на этой системе пока не поднимается — интерфейс можно посмотреть целиком, вход не обязателен.':
      'This system cannot run the tunnel yet — you can still explore the whole interface, no sign-in required.',
  'Ключ из аккаунта поднимает туннель прямо в приложении. Интерфейс можно посмотреть и без входа.':
      'The key from your account raises the tunnel right in the app. You can explore the interface without signing in.',
  'VPN-ключ / Код входа': 'VPN key / login code',
  'Посмотреть без входа': 'Look around without signing in',
  'Показать знакомство': 'Show intro',

  // ---- paywall.dart ----
  'Продлить подписку': 'Renew subscription',
  'тарифы': 'plans',
  'устройства': 'devices',
  '+50 ₽/мес за каждое доп-устройство · максимум 10': '+50 ₽/mo per extra device · 10 max',
  'число устройств (1–10) выбирается в боте при оплате · +50 ₽/мес за доп-устройство':
      'device count (1–10) is chosen in the bot at checkout · +50 ₽/mo per extra device',
  'выбор большинства': 'most popular',
  'Итого': 'Total',
  'VIP: цена считается по тарифу на 10 устройств — точный итог покажет бот':
      'VIP: priced as the 10-device plan — the bot shows the exact total',
  'Оплатить': 'Pay',
  'оплата на сайте — СБП или крипта': 'pay on the website — SBP or crypto',
  'оплата в боте — Stars, СБП, крипта или токены': 'pay in the bot — Stars, SBP, crypto or tokens',
  'оплата картой в Google Play · 1 устройство': 'card payment in Google Play · 1 device',
  'оплата через Google Play': 'payment via Google Play',
  'Google Play недоступен — попробуй позже': 'Google Play unavailable — try again later',
  'Открываю оплату…': 'Opening checkout…',
  'Проверяю покупку…': 'Verifying purchase…',
  'Подписка активна 🙌': 'Subscription active 🙌',
  'Покупка не подтверждена — напиши в поддержку': 'Purchase not confirmed — contact support',
  'Оплата не прошла — попробуй ещё раз': 'Payment failed — try again',
  'Оплата не открылась — попробуй ещё раз': "Couldn't open checkout — try again",
  'Магазин недоступен — попробуй позже': 'Store unavailable — try again later',
  'Продукт ещё не создан в Play Console (sub_mo/sub_q/sub_h/sub_yr)':
      'Product not created in Play Console yet (sub_mo/sub_q/sub_h/sub_yr)',
  'Тариф не найден': 'Plan not found',

  // ---- stats card (account.dart) ----
  'статистика': 'stats',
  'твоя история с bitaps': 'your history with bitaps',
  'с нами с': 'member since',
  'оплачено дней': 'days paid',
  'друзей приглашено': 'friends invited',
  'токены': 'tokens',

  // ---- tray (main.dart) ----
  'Показать окно': 'Show window',
  'Скрыть окно': 'Hide window',
  'Выйти из bitaps': 'Quit bitaps',
  'Подключить': 'Connect',
  'Режим': 'Mode',
  'Открыть bitaps': 'Open bitaps',
  'Не вошёл': 'Not signed in',
  'Подписка активна': 'Subscription active',
  'Подписка неактивна': 'Subscription inactive',

  // ---- deep-link / share / QR (native.dart, account.dart) ----
  'Ты уже вошёл': "You're already signed in",
  'Не удалось разобрать ссылку': "Couldn't parse the link",
  'Вход по ссылке': 'Sign-in link',
  'Войти в аккаунт по ссылке?': 'Sign in to the account via this link?',
  'Это не VPN-ключ': 'This is not a VPN key',
  'Показать QR': 'Show QR',
  'QR ключа': 'Key QR',
  'QR кода входа': 'Login code QR',
  'Реферальный QR': 'Referral QR',
  'Наведи камеру другого устройства': 'Point another device\'s camera at it',
  'Отсканируй в VPN-клиенте или другом устройстве': 'Scan it in a VPN client or another device',
  'Отсканируй в приложении bitaps на другом устройстве': 'Scan it in the bitaps app on another device',
  'Друг наводит камеру — и попадает в бота по твоей ссылке': 'A friend points their camera — and lands in the bot via your link',
  'Отправить на другое устройство': 'Send to another device',
  'Скопировано для отправки': 'Copied for sharing',

  // ---- автозапуск / хоткей (settings.dart, native.dart) ----
  'система': 'system',
  'Запускать при входе': 'Launch at login',
  'Автостарт вместе с системой': 'Start automatically with the system',
  'Старт свёрнутым': 'Start minimized',
  'При автозапуске — сразу в трей': 'On autostart — straight to the tray',
  'Не удалось изменить автозапуск': "Couldn't change autostart",
  'Хоткей подключения': 'Connect hotkey',
  'Нажми сочетание клавиш…': 'Press a key combination…',
  'Глобально включает/выключает VPN': 'Globally toggles the VPN',
  'Добавь модификатор (Cmd/Ctrl/Shift)': 'Add a modifier (Cmd/Ctrl/Shift)',
  'Подключаю…': 'Connecting…',
  'Отключаю…': 'Disconnecting…',
  'Демо-подключение…': 'Demo connection…',

  // ---- самодиагностика (settings.dart) ----
  'Проверить мой доступ': 'Check my access',
  'Проверка доступа': 'Access check',
  'Не вошёл — войди в Кабинете': 'Not signed in — sign in on the Account tab',
  'Подписка неактивна — продли в Кабинете': 'Subscription inactive — renew on the Account tab',
  'Ключ доступа получен': 'Access key received',
  'Ключ ещё не подтянут — нажми «Обновить»': 'Key not pulled yet — tap "Refresh"',
  'Код входа доступен (для входа без ключа)': 'Login code available (to sign in without a key)',
  'Кода входа нет — получи в боте (/start → Код входа)': 'No login code — get one in the bot (/start → Login code)',
  'Диагностика проверяет доступ к аккаунту, не качество канала.': 'Diagnostics checks account access, not channel quality.',
  'Подключение сейчас демонстрационное — реального туннеля нет.': 'The connection is currently a demo — no real tunnel.',

  // ---- что нового (settings.dart) ----
  'Что нового': "What's new",
  'Список изменений пока недоступен. Загляни позже.': 'The changelog is unavailable right now. Check back later.',

  // ---- faq (account) ----
  'Сколько устройств можно подключить?': 'How many devices can I connect?',
  'От 1 до 10 — число выбираешь при покупке (в боте или на сайте). Каждое дополнительное: +50 ₽/мес.':
      'From 1 to 10 — you pick the count at checkout (in the bot or on the website). Each extra device: +50 ₽/mo.',
  'Вы ведёте логи?': 'Do you keep logs?',
  'Нет. Мы не храним логи активности — только техническую информацию для работы сервиса.':
      "No. We don't store activity logs — only technical info to run the service.",
  'Как продлить подписку?': 'How do I renew my subscription?',
  'В «Кабинете» нажми «Продлить» — оплата через Telegram, СБП или крипту.':
      'In "Account" tap "Renew" — pay via Telegram, SBP or crypto.',
  'VPN не подключается?': "VPN won't connect?",
  'Смени локацию, проверь интернет и что подписка активна. Не помогло — напиши в поддержку.':
      'Switch location, check your internet and that your subscription is active. Still stuck — message support.',

  // ---- сообщения движка, сети и разбора подписки ----
  // Эти строки бросаются исключениями и показываются тостом, поэтому tr() к ним применяется
  // в самом тосте (см. _toast в main.dart). Без словаря они оставались русскими в EN.
  'нужно разрешить приложению создавать VPN-подключение': 'you need to allow the app to create a VPN connection',
  'Непонятный ответ сервера. Попробуй позже.': 'Unexpected server response. Try again later.',
  'VPN-движок не найден в сборке': 'VPN engine not found in this build',
  'VPN-движок не установлен в этой сборке': 'VPN engine is not bundled in this build',
  'VPN-движок ещё не установлен в этой сборке': 'VPN engine is not bundled in this build yet',
  'Не удалось запустить туннель': 'Could not start the tunnel',
  'не удалось включить системный прокси': 'could not enable the system proxy',
  'движок туннеля неожиданно завершил работу': 'the tunnel engine quit unexpectedly',
  'в подписке нет узлов, поддерживаемых этой сборкой': 'the subscription has no nodes supported by this build',
  'в подписке нет узлов, которые понимает движок': 'the subscription has no nodes the engine understands',
  'в подписке нет узлов для подключения': 'the subscription has no nodes to connect to',
  'выбранный сервер отсутствует в подписке': 'the selected server is not in the subscription',
  'подписка не ответила вовремя': 'the subscription did not respond in time',
  'не удалось получить подписку': 'could not fetch the subscription',
  'подписка: ожидался JSON-массив конфигов': 'subscription: expected a JSON array of configs',
  'не удалось разобрать ключ': 'could not parse the key',
  'Этот ключ не поддерживается этой сборкой': 'This key is not supported by this build',
  'Нужен ключ vless:// (или trojan/vmess/ss/hysteria2). Другой формат не поддерживается.':
      'A vless:// key is required (or trojan/vmess/ss/hysteria2). Other formats are not supported.',
  'Мой ключ': 'My key',

  // ---- пустой список серверов: причина и что делать ----
  'Список серверов приходит вместе с подпиской.': 'The server list comes with your subscription.',
  'Отключи лишнее устройство в «Кабинете» или расширь лимит — и серверы появятся.':
      'Remove an extra device in "Account" or raise the limit — the servers will show up.',
  'Проверь подписку в «Кабинете» и обнови список.': 'Check your subscription in "Account" and refresh.',
  'Сначала нужны серверы — обнови подписку': 'Servers are needed first — refresh your subscription',
  // ответы сервиса выдачи (приходят по-русски независимо от языка приложения)
  // причина отказа из лога движка (проходит через tr() в момент показа)
  'локальный порт занят другим VPN-приложением — закройте его и попробуйте снова':
      'the local port is taken by another VPN app — close it and try again',
  'Лимит устройств исчерпан': 'Device limit reached',
  'Подписка отключена': 'Subscription disabled',
};
