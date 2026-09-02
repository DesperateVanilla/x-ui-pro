# 🚀 3X-UI Pro (3X-UI + Nginx)

Форк проекта [mozaroc/x-ui-pro](https://github.com/mozaroc/x-ui-pro) (основан на [GFW4Fun/x-ui-pro](https://github.com/GFW4Fun/x-ui-pro) и работах legiz-ru).

Оптимизированный скрипт автоматической установки панели **3X-UI** с поддержкой **VLESS-Reality**, **VLESS-WS**, **VLESS-XHTTP**, **Trojan-gRPC** и **Hysteria 2** через **Nginx**.

---

## 🔥 Особенности данной сборки

- 📦 **Всегда последняя версия панели**: Автоматическое скачивание актуального релиза панели [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui).
- 👤 **Единый клиент (Single Client)**: При первой установке автоматически создается один клиент (`first`) сразу под все протоколы (**VLESS REALITY**, **VLESS WS**, **VLESS XHTTP**, **Trojan gRPC**, **Hysteria 2**).
- ⚡ **Поддержка Hysteria 2**: Автоматическая настройка протокола Hysteria 2 (UDP/QUIC, TLS ALPN `h3`) с автоматическим открытием портов в UFW.
- 🤖 **Интеграция Cloudflare WARP**: Встроенный обход блокировок для ИИ-сервисов (OpenAI, ChatGPT, Claude) через локальный SOCKS5-прокси WARP.
- 🚀 **Поддержка XHTTP**: Автоматическая настройка нового протокола XHTTP для обхода блокировок.
- 🔒 **Nginx SSL & Snippet Routing**: Маскировка трафика, авто-продление SSL через Certbot, daily reload Nginx.
- 🌐 **Персональная страница подписки (Web Sub Page)**: Готовая красиво оформленная страница подписки под Sing-Box, Clash Meta и стандартные клиенты.
- 🛡️ **Автонастройка Firewall (UFW)**.
- 🎲 **Случайные фейковые сайты (150+ шаблонов)** для маскировки REALITY.

---

## 📂 Описание скриптов

В этом репозитории есть несколько полезных скриптов для разных задач:

- **`x-ui-pro.sh`** — Главный скрипт автоматической установки. Ставит панель с нуля и настраивает связку с Nginx и сертификатами.
- **`add_warp.sh`** — Скрипт для интеграции Cloudflare WARP и настройки маршрутизации на уже работающий сервер.
- **`x-ui-latest.sh`** — Аналог главного скрипта, используется для тестирования свежих фич (например, последняя версия панели с XHTTP).
- **`add_protocol.sh`** — Скрипт для безопасного добавления новых протоколов в *уже установленную* панель без перезаписи ваших клиентов и настроек.
- **`backup.sh`** — Утилита для создания резервной копии базы данных `x-ui.db` и важных конфигураций.

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
bash <(wget -qO- https://raw.githubusercontent.com/DesperateVanilla/x-ui-pro/master/x-ui-pro.sh) -install yes -panel 1 -ONLY_CF_IP_ALLOW no
```

### Параметры запуска:
| Флаг | Значение по умолчанию | Описание |
| --- | --- | --- |
| `-install` | `yes` | Автоматическая установка необходимых пакетов |
| `-panel` | `1` | Тип панели (3X-UI) |
| `-ONLY_CF_IP_ALLOW` | `no` | Ограничивать ли доступ к подпискам только IP Cloudflare |
| `-subdomain` | *(запрашивается)* | Ваш основной домен для панели и SSL |
| `-reality_domain` | *(запрашивается)* | Домен для REALITY |
| `-warp` | `no` | Автоматическая установка Cloudflare WARP и настройка обхода блокировок для ИИ-сервисов (OpenAI, Claude и др.) |

---

## 🤖 Интеграция Cloudflare WARP (на уже работающий сервер)

Если у вас уже установлен `x-ui` (без переустановки с нуля) и вы хотите добавить обход блокировок для ИИ-сервисов (OpenAI, ChatGPT, Claude) через SOCKS5-прокси WARP, запустите отдельный скрипт:

```bash
sudo su -c "bash <(wget -qO- https://raw.githubusercontent.com/DesperateVanilla/x-ui-pro/master/add_warp.sh)"
```

Скрипт автоматически установит `warp-cli`, переведет его в режим локального прокси и аккуратно обновит вашу конфигурацию X-UI (xrayTemplateConfig) для перенаправления доменов в WARP.

---

## ➕ Добавление протоколов (без переустановки)

Если у вас уже установлена и работает панель, и вы хотите безопасно добавить новый протокол (например, **AmneziaWG (AWG)**) без потери текущих настроек, клиентов и конфигураций Nginx, воспользуйтесь мини-скриптом:

```bash
sudo su -c "bash <(wget -qO- https://raw.githubusercontent.com/DesperateVanilla/x-ui-pro/master/add_protocol.sh) awg"
```

Скрипт автоматически считает ваши домены из рабочей базы 3x-ui, сгенерирует уникальный порт и путь, добавит подключение и привяжет к нему существующих клиентов. Панель перезапустится автоматически.

---

## 🗑️ Удаление

Для полного удаления панели и Nginx:

```bash
sudo su -c "bash <(wget -qO- https://raw.githubusercontent.com/DesperateVanilla/x-ui-pro/master/x-ui-pro.sh) -uninstall yes"
```

---

## 💾 Резервное копирование

```bash
sudo su -c "bash <(wget -qO- https://raw.githubusercontent.com/DesperateVanilla/x-ui-pro/master/backup.sh)"
```

---

## 📱 Скриншоты и ссылки подписки

После установки в консоли выведутся все данные для входа:
- **Панель управления**: `https://<ваш_домен>/<случайный_путь>/`
- **Страница подписки первого клиента**: `https://<ваш_домен>/<web_path>?name=first`

---

## 🛠️ Возможные проблемы и нюансы (Troubleshooting)

### Ошибка: `dpkg was interrupted` или пакеты не устанавливаются
Если в процессе установки вы получаете ошибки вида `E: dpkg was interrupted...`, `nginx.service does not exist` или `certbot: command not found`, это означает, что пакетный менеджер Ubuntu был прерван во время предыдущих обновлений или установок.

**Решение:**
Вручную восстановите состояние пакетов на сервере командой:
```bash
dpkg --configure -a
```
При необходимости (если есть поврежденные зависимости):
```bash
apt-get install -f
```
После успешного выполнения этих команд запустите скрипт установки повторно.

### Ошибка: `SSL could not be generated!`
Обычно возникает, если вы указали домен, который еще не привязан к IP-адресу вашего сервера, или вы используете проксирование Cloudflare (оранжевое облако) на момент получения сертификата (Let's Encrypt не может достучаться до сервера напрямую).

**Решение:** 
Убедитесь, что A-запись домена (или поддомена) ведет строго на IP-адрес вашего сервера. Если используете Cloudflare — отключите проксирование (сделайте облако серым / DNS Only) на время первой установки скрипта и генерации сертификата. После завершения установки можно включить проксирование обратно.

---

## 📜 Благодарности
- [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) — за актуальную панель управления.
- [GFW4Fun/x-ui-pro](https://github.com/GFW4Fun/x-ui-pro) & legiz-ru — за оригинальный концепт Nginx + 3X-UI.


## AI & Global Bypass Routing (WARP+)
The installer now features a fully automated integration with Cloudflare WARP+ and `roscomvpn` geo-databases to bypass advanced DPI and AI service geo-blocks (such as Google Gemini, Antigravity, ChatGPT, Claude).

**Features:**
- Installs official `cloudflare-warp` and proxies traffic via local SOCKS5.
- Automatically scrapes and applies a free **WARP+ Premium Key** from Telegram.
- Downloads optimized `geoip.dat` and `geosite.dat` from `hydraponique/roscomvpn`.
- Implements an anti-ECH (Encrypted Client Hello) routing fallback: all CIS IPs go `direct`, while ALL other foreign TCP/UDP traffic is forcefully routed through WARP+.
- Automatically enables `sniffing` in `routeOnly` mode for all inbounds.
- Mitigates HTTP/3 QUIC timeouts by blackholing UDP on port 443 for AI domains.
