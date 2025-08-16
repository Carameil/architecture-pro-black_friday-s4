# MongoDB Sharding + Replication Setup

Данный проект реализует шардированный кластер MongoDB с полной репликацией для максимальной отказоустойчивости приложения "Мобильный мир".

## Архитектура

### Config Servers Replica Set
- **configSrv-1** (Primary) - порт 27017
- **configSrv-2** (Secondary) - порт 27027  
- **configSrv-3** (Secondary) - порт 27037

### Shard 1 Replica Set
- **shard1-1** (Primary) - порт 27018
- **shard1-2** (Secondary) - порт 27028
- **shard1-3** (Secondary) - порт 27038

### Shard 2 Replica Set  
- **shard2-1** (Primary) - порт 27019
- **shard2-2** (Secondary) - порт 27029
- **shard2-3** (Secondary) - порт 27039

### Дополнительные компоненты
- **mongos Router** - маршрутизация запросов (порт 27020)
- **FastAPI App** - веб-приложение (порт 8080)
- **Init Container** - автоматическая инициализация всех Replica Sets

## Как запустить

Запускаем MongoDB кластер с репликацией и приложение (с автоматической инициализацией)

```bash
docker compose up -d
```

Дождитесь, пока все сервисы станут healthy (это может занять до 5-7 минут для полной инициализации всех Replica Sets).

Заполняем MongoDB данными

```bash
./scripts/mongo-init.sh
```

## Проверка статуса

### Проверка статуса всех сервисов
```bash
docker compose ps
```

Должны быть healthy:
- 3x configSrv (config servers)
- 6x shard (shard1-1,2,3 + shard2-1,2,3)  
- 1x mongos_router
- 1x pymongo_api

Init контейнер должен быть в статусе "exited (0)".

### Проверка статуса Replica Sets

#### Config Server RS
```bash
docker compose exec -T configSrv-1 mongosh --port 27017 --quiet <<EOF
rs.status()
EOF
```

#### Shard 1 RS
```bash
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.status()
EOF
```

#### Shard 2 RS
```bash
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
rs.status()
EOF
```

## Как работает автоматическая инициализация репликации

1. **Запуск базовых сервисов**: Все MongoDB узлы запускаются в режиме Replica Set
2. **Инициализация RS**: Init-контейнер последовательно инициализирует:
   - Config Server RS с 3 узлами
   - Shard1 RS с 3 узлами  
   - Shard2 RS с 3 узлами
3. **Запуск mongos**: Подключается ко всем Config Servers
4. **Запуск приложения**: FastAPI подключается к mongos

## Высокая доступность (HA)

### Отказоустойчивость
- **Config Servers**: Выдерживает отказ 1 узла из 3
- **Shard 1**: Выдерживает отказ 1 узла из 3
- **Shard 2**: Выдерживает отказ 1 узла из 3
- **Автоматическое переключение Primary** при сбоях

### Тестирование отказоустойчивости

#### Симуляция сбоя Secondary узла
```bash
docker compose stop shard1-2
# Проверка что кластер работает
curl http://localhost:8080/helloDoc/count
docker compose start shard1-2
```

#### Симуляция сбоя Primary узла (автоматическое переключение)
```bash
docker compose stop shard1-1
# Ожидание переключения Primary (30-60 сек)
docker compose exec -T shard1-2 mongosh --port 27018 --quiet <<EOF
rs.status()
EOF
# Проверка работоспособности
curl http://localhost:8080/helloDoc/count
```

## Настройка репликации (выполняется автоматически)

### Ручная инициализация (если нужна)

#### Config Server Replica Set
```bash
docker compose exec -T configSrv-1 mongosh --port 27017 --quiet <<EOF
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [
    { _id: 0, host: "configSrv-1:27017" },
    { _id: 1, host: "configSrv-2:27017" },
    { _id: 2, host: "configSrv-3:27017" }
  ]
});
EOF
```

#### Shard 1 Replica Set
```bash
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id: "shard1",
  members: [
    { _id: 0, host: "shard1-1:27018" },
    { _id: 1, host: "shard1-2:27018" },
    { _id: 2, host: "shard1-3:27018" }
  ]
});
EOF
```

#### Shard 2 Replica Set
```bash
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
rs.initiate({
  _id: "shard2",
  members: [
    { _id: 0, host: "shard2-1:27019" },
    { _id: 1, host: "shard2-2:27019" },
    { _id: 2, host: "shard2-3:27019" }
  ]
});
EOF
```

## Проверка работы шардирования и репликации

### Общее количество документов и шардов
```bash
curl http://localhost:8080/ | jq
```

### Количество документов по шардам
```bash
# Через Primary узлы
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

### Проверка репликации (данные должны быть на всех узлах)
```bash
# Shard1 Secondary узлы
docker compose exec -T shard1-2 mongosh --port 27018 --quiet <<EOF
rs.secondaryOk()
use somedb
db.helloDoc.countDocuments()
EOF

docker compose exec -T shard1-3 mongosh --port 27018 --quiet <<EOF
rs.secondaryOk()
use somedb
db.helloDoc.countDocuments()
EOF
```

## Мониторинг кластера

### Проверка Primary/Secondary ролей
```bash
# Config Server
docker compose exec -T configSrv-1 mongosh --port 27017 --quiet <<EOF
db.isMaster()
EOF

# Shard 1
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
db.isMaster()
EOF

# Shard 2  
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
db.isMaster()
EOF
```

### Статистика шардирования
```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.status()
EOF
```

## Диагностика

### Проверка сетевой связности между узлами
```bash
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.conf()
EOF
```

### Проверка лагов репликации
```bash
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.printSlaveReplicationInfo()
EOF
```

## Очистка и перезапуск

### Полная очистка
```bash
docker compose down -v
```

### Перезапуск без потери данных
```bash
docker compose restart
```

## Системные требования

- Docker & Docker Compose
- Минимум 8 ГБ RAM (9 MongoDB контейнеров)
- Минимум 4 CPU cores
- Рекомендуется SSD для лучшей производительности

## Порты

### Внешние порты
- `8080` - FastAPI приложение
- `27020` - mongos Router
- `27017` - configSrv-1 (Primary)
- `27018` - shard1-1 (Primary)  
- `27019` - shard2-1 (Primary)

### Дополнительные порты (Secondary узлы)
- `27027`, `27037` - configSrv-2,3
- `27028`, `27038` - shard1-2,3
- `27029`, `27039` - shard2-2,3

## Преимущества данной архитектуры

✅ **Полная отказоустойчивость**: Выдерживает отказ любого узла  
✅ **Автоматическое восстановление**: Primary selection при сбоях  
✅ **Горизонтальное масштабирование**: Данные распределены по шардам  
✅ **Балансировка нагрузки**: Чтение с Secondary узлов  
✅ **Production-ready**: Health checks, restart policies, автоинициализация  
✅ **Простое развертывание**: `docker compose up -d`