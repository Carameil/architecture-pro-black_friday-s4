#!/bin/bash
set -e

echo "🚀 Инициализация шардированного кластера MongoDB..."

echo "📋 Остановка и очистка предыдущего состояния..."
docker compose down -v >/dev/null 2>&1 || true

echo "🚀 Запуск базовых сервисов (без mongos и app)..."
docker compose up -d configSrv shard1 shard2

echo "📋 Проверка статуса базовых сервисов..."
docker compose ps

# Функция для проверки готовности сервиса
wait_for_mongo() {
    local service=$1
    local port=$2
    local max_attempts=30
    local attempt=0
    
    echo "⏳ Ожидание готовности $service на порту $port..."
    
    while [ $attempt -lt $max_attempts ]; do
        if docker compose exec -T $service mongosh --port $port --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            echo "✅ $service готов"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "🔄 Попытка $attempt/$max_attempts для $service..."
        sleep 2
    done
    
    echo "❌ Таймаут ожидания готовности $service"
    return 1
}

# Проверяем готовность всех базовых сервисов
wait_for_mongo "configSrv" "27017"
wait_for_mongo "shard1" "27018" 
wait_for_mongo "shard2" "27019"

echo "🔧 Инициализация Config Server..."
docker compose exec -T configSrv mongosh --port 27017 --quiet <<EOF
rs.initiate({
  _id : "config_server",
  configsvr: true,
  members: [{ _id : 0, host : "configSrv:27017" }]
});
EOF

# Ждем готовности Config Server как RS
echo "⏳ Ожидание готовности Config Server RS..."
for i in {1..30}; do
    if docker compose exec -T configSrv mongosh --port 27017 --quiet --eval "rs.status().ok" 2>/dev/null | grep -q "1"; then
        echo "✅ Config Server RS готов"
        break
    fi
    echo "🔄 Ожидание Config Server RS... ($i/30)"
    sleep 2
done

echo "🔧 Инициализация Shard 1..."
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id : "shard1",
  members: [{ _id : 0, host : "shard1:27018" }]
});
EOF

echo "🔧 Инициализация Shard 2..."
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
rs.initiate({
  _id : "shard2",
  members: [{ _id : 0, host : "shard2:27019" }]
});
EOF

# Ждем готовности шардов
echo "⏳ Ожидание готовности Shard RS..."
for i in {1..30}; do
    shard1_ready=$(docker compose exec -T shard1 mongosh --port 27018 --quiet --eval "rs.status().ok" 2>/dev/null | grep -q "1" && echo "yes" || echo "no")
    shard2_ready=$(docker compose exec -T shard2 mongosh --port 27019 --quiet --eval "rs.status().ok" 2>/dev/null | grep -q "1" && echo "yes" || echo "no")
    
    if [ "$shard1_ready" = "yes" ] && [ "$shard2_ready" = "yes" ]; then
        echo "✅ Все Shard RS готовы"
        break
    fi
    echo "🔄 Ожидание Shard RS... ($i/30) [Shard1: $shard1_ready, Shard2: $shard2_ready]"
    sleep 2
done

# Запускаем mongos_router после инициализации Config Server
echo "🚀 Запуск mongos_router..."
docker compose --profile manual up -d mongos_router

# Ждем готовности mongos
wait_for_mongo "mongos_router" "27020"

echo "🔧 Настройка шардирования..."
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1:27018");
sh.addShard("shard2/shard2:27019");
sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "name" : "hashed" });
EOF

echo "📊 Добавление тестовых данных..."
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
for(var i = 0; i < 1000; i++) db.helloDoc.insertOne({age:i, name:"ly"+i})
EOF

echo "✅ Проверка результатов..."
echo "📊 Общее количество документов:"
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

echo "📊 Документы в Shard 1:"
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

echo "📊 Документы в Shard 2:"
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

echo "🚀 Запуск приложения..."
docker compose --profile manual up -d pymongo_api

echo "⏳ Ожидание готовности приложения..."
sleep 10

echo "🎉 Инициализация завершена! Приложение доступно на http://localhost:8080"
echo "📋 Финальный статус сервисов:"
docker compose ps
