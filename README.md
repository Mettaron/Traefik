# Laba: локальна інфраструктура сервісів

Спільна dev-інфраструктура всіх сервісів Laba: один Traefik, одна мережа `laba_network`, реєстр
сервісів `services.yaml` і команди, що клонують та піднімають сервіси.

```
Laba/
├── Traefik/                    # цей репозиторій
│   ├── Makefile                # усі команди
│   ├── services.yaml           # реєстр сервісів (закомічений)
│   ├── services.local.yaml     # особисті гілки й ключі (gitignored), див. .example
│   ├── bin/                    # svc-field, svc-secret, gen-traefik (+ registry.py)
│   ├── docker-compose.yml      # сам Traefik
│   ├── traefik.yml             # статичний конфіг Traefik
│   ├── dynamic/                # спільні middleware + згенеровані fallback-роутери
│   └── generated/              # згенеровані aliases Traefik (gitignored)
├── Services/<service>/         # сервіси, створені з template-symfony-service
└── Bundles/                    # бандли
```

У Docker Desktop усе має префікс `laba_`: `laba_traefik`, мережа `laba_network`, проєкт кожного
сервісу `laba_<service>` з контейнерами `laba_<service>_app`, `_worker`, `_db`.

## Швидкий старт

```bash
cp services.local.yaml.example services.local.yaml   # перелічи потрібні сервіси (і гілки)
make run                                              # clone того, чого ще нема + up
```

- Traefik: http://traefik.localhost:8080/dashboard/
- сервіс: `http://<service>.localhost` (API: `/api/docs`)

Сервіс можна піднімати й з його власного репозиторію (`make up` у `Services/<service>`): `make up`
тут викликає саме його, тож результат однаковий.

## Команди

`SERVICES=` приймає сервіси, групи з `groups:` у `services.yaml` і `all`; за замовчуванням — усе,
що перелічено в `services.local.yaml`. `BRANCH=...` форсує гілку для всіх.

| Команда | Що робить |
|---|---|
| `make run` | `clone` + `up` одним кроком |
| `make clone` | клонує відсутні `SERVICES` у `../Services/` на їхній гілці |
| `make checkout` | перемикає вже склоновані `SERVICES` на їхню гілку |
| `make up` | Traefik + ключі (`secrets`) + `make up` кожного сервісу; попереджає, якщо гілка не та |
| `make stop` | зупиняє `SERVICES`, контейнери лишаються в Docker Desktop |
| `make down` | зупиняє й прибирає контейнери `SERVICES` (БД і Traefik лишаються) |
| `make ps` | контейнери в `laba_network` |
| `make check` | реєстр без дублікатів `db_port` / хостів і невідомих учасників груп |
| `make gen` | генерує aliases Traefik і fallback-роутери з реєстру |
| `make traefik-up` / `traefik-down` | лише Traefik |
| `make secrets` | пише міжсервісні API-ключі в `.env.local` сервісів |
| `make rekey SERVICE=x` | після зміни `api_key` сервісу `x` — оновлює `.env.local` його споживачів |

## Реєстр сервісів

`services.yaml` — єдине місце, де описано сервіс (поля пояснено на початку файлу):

```yaml
groups:
  payment: payment-gateway payment-merchant

payment-gateway:
  repo: Mettaron/payment-gateway
  db_port: 33061
  staging_origin: https://payment-gateway.stage.example
  api_key: null
  keys:
    CMS_API_KEY: cms
```

Aliases Traefik і fallback-роутери генеруються з нього (`make gen`, `make traefik-up` робить це
сам), вручну їх не ведемо.

`services.local.yaml` (gitignored) має ту саму форму і перекриває поля — як `.env.local`:
`branch:` для clone/checkout, справжні `api_key:`. Сервіс, перелічений там, входить у `SERVICES`
за замовчуванням.

## `.localhost` і `.local`

- `<service>.localhost` — для браузера.
- `<service>.local` — для викликів **з коду одного сервісу до іншого**: у контейнері curl
  резолвить `*.localhost` у сам контейнер (RFC 6761), тож виклик потрапив би в себе ж. Кожна
  `*_URL`-змінна до іншого сервісу — на `.local`.

Обидва хости — aliases контейнера `laba_traefik` у `laba_network`, тож працюють з будь-якого
контейнера мережі.

## Fallback на stage

Сервіс з `staging_origin` отримує низькопріоритетний роутер (`dynamic/fallback-<service>.yml`):
коли локальний контейнер не запущено, запити на його `.localhost` / `.local` ідуть на stage.
Запущений локально сервіс (пріоритет 99) завжди перемагає. Після зупинки сервісу Traefik
перемикається за кілька секунд.

## API-ключі між сервісами

- `services.yaml`: у сервісу, якого викликають з ключем, — `api_key: null` (лише мітка, значення
  не комітимо); у того, хто викликає, — `keys:` (`ЗМІННА_В_.env: сервіс`).
- `services.local.yaml`: справжнє значення, `<service>: api_key: ...`.
- `make secrets` (і `make up`) пише значення в `.env.local` споживачів, в окремий позначений блок;
  рядки, вписані вручну, не чіпає. Ключ без значення пропускається з попередженням.

## Новий сервіс

1. GitHub → *Use this template* з `template-symfony-service`, клон у `Laba/Services/<service>`.
2. Попросити AI-асистента виконати `INIT_SERVICE.md` сервісу: він замінить назву й зареєструє
   сервіс тут (`services.yaml`, наступний `db_port`).
3. `make up SERVICES=<service>`.

## Діагностика

```bash
make ps                                               # хто в мережі
curl -s http://127.0.0.1:8080/api/http/routers | jq   # роутери Traefik
docker network inspect laba_network
tail -f logs/access.log                               # який роутер/сервіс обробив запит
```

Сервіс недоступний: перевір, що контейнер healthy (`make ps` у сервісі) — Traefik не роутить на
нездоровий контейнер, а перший запуск (composer install) займає кілька хвилин.
