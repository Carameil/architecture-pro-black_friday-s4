#!/bin/bash

###
# Инициализация шардированной БД с репликацией
###

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

echo "📋 Статус Replica Sets:"
echo "Config Server RS:"
docker compose exec -T configSrv-1 mongosh --port 27017 --quiet <<EOF
rs.status().members.forEach(m => print(m.name + " - " + m.stateStr))
EOF

echo "Shard 1 RS:"
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.status().members.forEach(m => print(m.name + " - " + m.stateStr))
EOF

echo "Shard 2 RS:"
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
rs.status().members.forEach(m => print(m.name + " - " + m.stateStr))
EOF

echo "🎉 Инициализация завершена! Данные распределены по шардам с репликацией."
echo "🌐 Приложение с кешированием доступно на http://localhost:8080"
echo "📊 API информация: http://localhost:8080/docs"
echo ""
echo "🔧 Redis кеширование активировано для эндпоинтов:"
echo "• GET /helloDoc/users - кешируется на 60 секунд"
echo "• GET /helloDoc/users/{name} - кешируется на 60 секунд"
echo ""
echo "🧪 Для тестирования производительности кеша:"
echo "time curl http://localhost:8080/helloDoc/users  # Первый запрос (Cache Miss)"
echo "time curl http://localhost:8080/helloDoc/users  # Повторный запрос (Cache Hit <100мс)"