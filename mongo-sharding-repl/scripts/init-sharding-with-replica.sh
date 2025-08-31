#!/bin/bash
set -e

###
# Инициализация шардированного кластера MongoDB с полной репликацией
# Используется для проекта mongo-sharding-repl
###

echo "🚀 Инициализация шардированного кластера MongoDB с репликацией..."

echo "📋 Остановка и очистка предыдущего состояния..."
docker compose down -v >/dev/null 2>&1 || true

echo "🚀 Запуск всех MongoDB узлов..."
docker compose up -d configSrv-1 configSrv-2 configSrv-3 shard1-1 shard1-2 shard1-3 shard2-1 shard2-2 shard2-3

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

# Проверяем готовность всех узлов
echo "⏳ Проверка готовности Config Servers..."
wait_for_mongo "configSrv-1" "27017"
wait_for_mongo "configSrv-2" "27017" 
wait_for_mongo "configSrv-3" "27017"

echo "⏳ Проверка готовности Shard 1 узлов..."
wait_for_mongo "shard1-1" "27018"
wait_for_mongo "shard1-2" "27018"
wait_for_mongo "shard1-3" "27018"

echo "⏳ Проверка готовности Shard 2 узлов..."
wait_for_mongo "shard2-1" "27019"
wait_for_mongo "shard2-2" "27019"
wait_for_mongo "shard2-3" "27019"

echo "🔧 Инициализация Config Server Replica Set..."
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

echo "🔧 Инициализация Shard 1 Replica Set..."
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

echo "🔧 Инициализация Shard 2 Replica Set..."
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

# Ждем готовности всех Replica Sets
echo "⏳ Ожидание готовности всех Replica Sets (это может занять 60-90 секунд)..."
for i in {1..45}; do
    config_ready=$(docker compose exec -T configSrv-1 mongosh --port 27017 --quiet --eval "rs.status().ok" 2>/dev/null | grep -q "1" && echo "yes" || echo "no")
    shard1_ready=$(docker compose exec -T shard1-1 mongosh --port 27018 --quiet --eval "rs.status().ok" 2>/dev/null | grep -q "1" && echo "yes" || echo "no")
    shard2_ready=$(docker compose exec -T shard2-1 mongosh --port 27019 --quiet --eval "rs.status().ok" 2>/dev/null | grep -q "1" && echo "yes" || echo "no")
    
    if [ "$config_ready" = "yes" ] && [ "$shard1_ready" = "yes" ] && [ "$shard2_ready" = "yes" ]; then
        echo "✅ Все Replica Sets готовы"
        break
    fi
    echo "🔄 Ожидание RS... ($i/45) [Config: $config_ready, Shard1: $shard1_ready, Shard2: $shard2_ready]"
    sleep 2
done

echo "🚀 Запуск mongos_router..."
docker compose up -d mongos_router

# Ждем готовности mongos
wait_for_mongo "mongos_router" "27020"

echo "🔧 Настройка шардирования..."
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018");
sh.addShard("shard2/shard2-1:27019,shard2-2:27019,shard2-3:27019");
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

echo "📊 Документы в Shard 1 (Primary узел):"
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

echo "📊 Документы в Shard 2 (Primary узел):"
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

echo "🔍 Проверка репликации в Shard 1 (Secondary узел):"
docker compose exec -T shard1-2 mongosh --port 27018 --quiet <<EOF
rs.secondaryOk()
use somedb
db.helloDoc.countDocuments()
EOF

echo "🔍 Проверка репликации в Shard 2 (Secondary узел):"
docker compose exec -T shard2-2 mongosh --port 27019 --quiet <<EOF
rs.secondaryOk()
use somedb
db.helloDoc.countDocuments()
EOF

echo "🚀 Запуск приложения..."
docker compose up -d pymongo_api

echo "⏳ Ожидание готовности приложения..."
sleep 15

echo "📋 Статус всех Replica Sets:"
echo "=== Config Server RS ==="
docker compose exec -T configSrv-1 mongosh --port 27017 --quiet <<EOF
rs.status().members.forEach(m => print(m.name + " - " + m.stateStr))
EOF

echo "=== Shard 1 RS ==="
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.status().members.forEach(m => print(m.name + " - " + m.stateStr))
EOF

echo "=== Shard 2 RS ==="
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
rs.status().members.forEach(m => print(m.name + " - " + m.stateStr))
EOF

echo "🎉 Инициализация завершена! Приложение доступно на http://localhost:8080"
echo "📋 Финальный статус сервисов:"
docker compose ps

echo ""
echo "🧪 Для тестирования используйте:"
echo "curl http://localhost:8080/ | jq"
echo "curl http://localhost:8080/helloDoc/count"
echo "curl http://localhost:8080/helloDoc/users | jq '.users | length'"
