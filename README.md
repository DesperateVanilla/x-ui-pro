# 🚀 3X-UI Pro (3X-UI + Nginx)

Форк проекта [mozaroc/x-ui-pro](https://github.com/mozaroc/x-ui-pro) (основан на [GFW4Fun/x-ui-pro](https://github.com/GFW4Fun/x-ui-pro) и работах legiz-ru).

Оптимизированный скрипт автоматической установки панели **3X-UI** с поддержкой **VLESS-Reality**, **VLESS-WS**, **Trojan-gRPC** и **Hysteria 2** через **Nginx**.

---

## 🔥 Особенности данной сборки

- 📦 **Всегда последняя версия панели**: Автоматическое скачивание актуального релиза панели [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui).
- 👤 **Единый клиент (Single Client)**: При первой установке автоматически создается один клиент (`first`) сразу под все протоколы (**VLESS REALITY**, **VLESS WS**, **Trojan gRPC**, **Hysteria 2**).
- ⚡ **Поддержка Hysteria 2**: Автоматическая настройка протокола Hysteria 2 (UDP/QUIC, TLS ALPN `h3`) с автоматическим открытием портов в UFW.
- 🧹 **Очистка от устаревшего**: Удален нерабочий протокол XHTTP.
- 🔒 **Nginx SSL & Snippet Routing**: Маскировка трафика, авто-продление SSL через Certbot, daily reload Nginx.
- 🌐 **Персональная страница подписки (Web Sub Page)**: Готовая красиво оформленная страница подписки под Sing-Box, Clash Meta и стандартные клиенты.
- 🛡️ **Автонастройка Firewall (UFW)**.
- 🎲 **Случайные фейковые сайты (150+ шаблонов)** для маскировки REALITY.

---

## 📋 Требования

> ⚠️ **Вам понадобятся 2 домена (или поддомена):**
> 1. **Основной домен (Panel & Inbounds)** — для панели, подписок, VLESS-WS, Trojan-gRPC и Hysteria 2. (A-запись указывать на IP сервера).
> 2. **Reality домен (Target)** — назначение для маскировки VLESS-Reality.

Совместимые ОС: **Ubuntu 20.04 / 22.04 / 24.04**, **Debian 11 / 12**.

---

## 💻 Установка

Запустите команду на чистом сервере под пользователем `root`:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/mozaroc/x-ui-pro/master/x-ui-pro.sh) -install yes -panel 1 -ONLY_CF_IP_ALLOW no
```

### Параметры запуска:
| Флаг | Значение по умолчанию | Описание |
| --- | --- | --- |
| `-install` | `yes` | Автоматическая установка необходимых пакетов |
| `-panel` | `1` | Тип панели (3X-UI) |
| `-ONLY_CF_IP_ALLOW` | `no` | Ограничивать ли доступ к подпискам только IP Cloudflare |
| `-subdomain` | *(запрашивается)* | Ваш основной домен для панели и SSL |
| `-reality_domain` | *(запрашивается)* | Домен для REALITY |

---

## 🗑️ Удаление

Для полного удаления панели и Nginx:

```bash
sudo su -c "bash <(wget -qO- https://raw.githubusercontent.com/mozaroc/x-ui-pro/master/x-ui-pro.sh) -uninstall yes"
```

---

## 💾 Резервное копирование

```bash
sudo su -c "bash <(wget -qO- https://raw.githubusercontent.com/mozaroc/x-ui-pro/master/backup.sh)"
```

---

## 📱 Скриншоты и ссылки подписки

После установки в консоли выведутся все данные для входа:
- **Панель управления**: `https://<ваш_домен>/<случайный_путь>/`
- **Страница подписки первого клиента**: `https://<ваш_домен>/<web_path>?name=first`

---

## 📜 Благодарности
- [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) — за актуальную панель управления.
- [GFW4Fun/x-ui-pro](https://github.com/GFW4Fun/x-ui-pro) & legiz-ru — за оригинальный концепт Nginx + 3X-UI.
