# MongoDB Sharding Setup

Данный проект реализует шардированный кластер MongoDB для высоконагруженного приложения "Мобильный мир".

## Архитектура

- **1x Config Server** (`configSrv`) - хранение метаданных кластера (порт 27017)
- **2x Shards** (`shard1`, `shard2`) - распределенное хранение данных (порты 27018, 27019)
- **1x mongos Router** (`mongos_router`) - маршрутизация запросов (порт 27020)
- **1x FastAPI App** (`pymongo_api`) - веб-приложение (порт 8080)
- **1x Init Container** (`mongo-init`) - автоматическая инициализация Replica Sets

## Как запустить

Запускаем mongodb кластер и приложение (с автоматической инициализацией)

```bash
docker compose up -d
```

Дождитесь, пока все сервисы станут healthy (это может занять до 3-4 минут).

Заполняем mongodb данными

```bash
./scripts/mongo-init.sh
```

## Проверка статуса

```bash
docker compose ps
```

Все основные сервисы должны быть в статусе "healthy", а `mongo-init` в статусе "exited (0)".

## Как работает автоматическая инициализация

1. **Запуск базовых сервисов**: `configSrv`, `shard1`, `shard2` запускаются первыми
2. **Инициализация RS**: `mongo-init` контейнер автоматически инициализирует все Replica Sets
3. **Запуск mongos**: После успешной инициализации запускается `mongos_router`
4. **Запуск приложения**: `pymongo_api` запускается после готовности mongos

## Ручная инициализация (опционально)

Если нужна ручная инициализация с более подробным выводом:

#### 3.1. Инициализация Config Server

```bash
docker compose exec -T configSrv mongosh --port 27017 --quiet <<EOF
rs.initiate(
  {
    _id : "config_server",
    configsvr: true,
    members: [
      { _id : 0, host : "configSrv:27017" }
    ]
  }
);
EOF
```

#### 3.2. Инициализация Shard 1

```bash
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
rs.initiate(
  {
    _id : "shard1",
    members: [
      { _id : 0, host : "shard1:27018" }
    ]
  }
);
EOF
```

#### 3.3. Инициализация Shard 2

```bash
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
rs.initiate(
  {
    _id : "shard2",
    members: [
      { _id : 1, host : "shard2:27019" }
    ]
  }
);
EOF
```

#### 3.4. Настройка шардирования через mongos

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1:27018");
sh.addShard("shard2/shard2:27019");
sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "name" : "hashed" });
EOF
```

#### 3.5. Добавление тестовых данных

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
for(var i = 0; i < 1000; i++) db.helloDoc.insertOne({age:i, name:"ly"+i})
EOF
```

## Проверка работы шардирования

### Проверка общего количества документов

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Ожидаемый результат: **1000 документов**

### Проверка распределения по шардам

#### Количество документов в Shard 1:

```bash
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

#### Количество документов в Shard 2:

```bash
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

**Примечание**: Сумма документов в обоих шардах должна равняться 1000. Распределение может быть примерно 50/50 благодаря hashed шардированию по полю `name`.

## Проверка через веб-приложение

После успешной инициализации откройте:

- **Приложение**: http://localhost:8080
- **API документация**: http://localhost:8080/docs

### Ключевые эндпоинты:

- `GET /` - информация о кластере, количество документов и список шардов
- `GET /helloDoc/count` - общее количество документов в коллекции
- `GET /helloDoc/users` - список пользователей (до 1000)

## Диагностика

### Проверка статуса шардов

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.status()
EOF
```

### Просмотр информации о шардах

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
db.adminCommand("listShards")
EOF
```

### Проверка статуса Replica Sets

```bash
# Config Server
docker compose exec -T configSrv mongosh --port 27017 --quiet <<EOF
rs.status()
EOF

# Shard 1
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
rs.status()
EOF

# Shard 2
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
rs.status()
EOF
```

## Остановка и очистка

```bash
# Остановка сервисов
docker compose down

# Полная очистка (включая данные)
docker compose down -v
```

## Системные требования

- Docker & Docker Compose
- Минимум 4 ГБ RAM
- Минимум 2 CPU cores

## Порты

- `8080` - FastAPI приложение
- `27017` - Config Server
- `27018` - Shard 1
- `27019` - Shard 2
- `27020` - mongos Router