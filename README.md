# Laba: локальна інфраструктура сервісів

Спільна dev-інфраструктура всіх сервісів Laba: один Traefik, спільний Redis, одна мережа `laba_network`,
реєстр сервісів `services.yaml` і команди, що клонують та піднімають сервіси.

```
Laba/
├── Traefik/                    # цей репозиторій
│   ├── Makefile                # усі команди
│   ├── AGENTS.md, CLAUDE.md    # правила для AI-асистента: карта Laba і правила цього репо
│                               # (`make claude-md` підключає їх до всього Laba/ через Laba/CLAUDE.md)
│   ├── services.yaml           # реєстр сервісів (закомічений)
│   ├── services.local.yaml     # особисті гілки й ключі (gitignored), див. .example
│   ├── bin/                    # svc-field, svc-secret, gen-traefik (+ registry.py)
│   ├── docker-compose.yml      # Traefik, спільний Redis (laba_redis) і Redis Insight
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
make claude-md                                        # один раз: правила AI-асистента для всього Laba/
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
| `make traefik-up` / `traefik-down` | лише Traefik, спільний Redis і його панель Redis Insight |
| `make redis-cli` | `redis-cli` спільного Redis |
| `make status` | стан усіх репозиторіїв Laba: незакомічене, не запушене, комітів після останнього тегу |
| `make secrets` | пише міжсервісні API-ключі в `.env.local` сервісів |
| `make rekey SERVICE=x` | після зміни `api_keys` сервісу `x` — оновлює `.env.local` його і тих, хто його викликає |
| `make claude-md` | створює `Laba/CLAUDE.md` з `@Traefik/AGENTS.md`: Claude Code підхоплює його в кожному репозиторії під `Laba/` |

## Реєстр сервісів

`services.yaml` — єдине місце, де описано сервіс (поля пояснено на початку файлу):

```yaml
groups:
  payment: payment-gateway payment-merchant

payment-gateway:
  repo: Mettaron/payment-gateway
  db_port: 55001
  staging_origin: https://payment-gateway.stage.example
  keys:
    CMS_API_KEY: cms
```

Aliases Traefik і fallback-роутери генеруються з нього (`make gen`, `make traefik-up` робить це
сам), вручну їх не ведемо.

`services.local.yaml` (gitignored) має ту саму форму і перекриває поля — як `.env.local`:
`branch:` для clone/checkout, справжні ключі `api_keys:`. Сервіс, перелічений там, входить у `SERVICES`
за замовчуванням.

## `.localhost` і `.local`

- `<service>.localhost` — для браузера.
- `<service>.local` — для викликів **з коду одного сервісу до іншого**: у контейнері curl
  резолвить `*.localhost` у сам контейнер (RFC 6761), тож виклик потрапив би в себе ж. Кожна
  `*_URL`-змінна до іншого сервісу — на `.local`.

Обидва хости — aliases контейнера `laba_traefik` у `laba_network`, тож працюють з будь-якого
контейнера мережі.

## Спільний Redis (`global_cache`)

`laba_redis` — Redis-кеш, спільний для всіх сервісів (`laba_client.global_cache` з `laba/client-bundle`):
сервіс-власник даних пише в нього, інші читають. Піднімається разом із Traefik.

- у сервісі: `REDIS_CACHE_DSN=redis://laba_redis:6379` у `.env.local` і секція `global_cache`
  у `config/packages/laba_client.yaml`;
- з хоста (GUI-клієнт): `127.0.0.1:6379` (`REDIS_PORT` у `.env`), консоль — `make redis-cli`.
- у браузері: <http://redis.localhost> — Redis Insight (`laba_redisinsight`): ключі, значення, TTL,
  редагування й видалення. З'єднання з `laba_redis` уже налаштоване; при першому відкритті
  Redis Insight попросить прийняти свою ліцензію.

Це лише кеш: на диск нічого не зберігається, після перезапуску контейнер порожній.

## Fallback на stage

Сервіс з `staging_origin` отримує низькопріоритетний роутер (`dynamic/fallback-<service>.yml`):
коли локальний контейнер не запущено, запити на його `.localhost` / `.local` ідуть на stage.
Запущений локально сервіс (пріоритет 99) завжди перемагає. Після зупинки сервісу Traefik
перемикається за кілька секунд.

## API-ключі між сервісами

Окремий ключ на кожну пару «хто викликає → кого»: витік одного ключа не відкриває інших сервісів,
а сервіс, якого викликають, знає, хто саме прийшов (`laba_service.api_access` з `laba/service-bundle`
дає йому роль за ключем).

- `services.yaml`: той, хто викликає, оголошує `keys:` — змінна в його `.env.local` і сервіс, до якого
  вона: `USERS_API_KEY: users`. Значень тут немає.
- `services.local.yaml`: справжні значення — у сервісу, якого викликають, `api_keys:` по ключу на
  кожного, хто його викликає:

  ```yaml
  users:
    api_keys:
      cms: <ключ>        # новий ключ: python3 -c 'import secrets; print(secrets.token_hex(32))'
      payment: <ключ>
  ```

- `make secrets` (і `make up`) пише ключ пари обом сторонам, в окремий позначений блок `.env.local`:
  тому, хто викликає, — у його змінну з `keys:` (`USERS_API_KEY`); тому, кого викликають, —
  `API_CLIENT_<ХТО>_KEY` (`API_CLIENT_CMS_KEY`), яку читає його конфіг:

  ```yaml
  # config/packages/laba_service.yaml сервісу users
  laba_service:
      api_access:
          clients:
              cms: { key: '%env(API_CLIENT_CMS_KEY)%', description: '...' }
  ```

  Рядки, вписані вручну, не чіпає; ключ без значення пропускається з попередженням.
- Змінили ключі сервісу — `make rekey SERVICE=users`: оновить його і всіх, хто його викликає.
- `make check` знаходить у `api_keys` сервіс, який насправді його не викликає (немає `keys:`).

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
