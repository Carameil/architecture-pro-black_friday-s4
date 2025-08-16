#!/bin/bash
set -e

###
# Инициализация Redis кластера для кеширования
# Создает кластер из 6 узлов: 3 master + 3 slave
###

echo "🚀 Инициализация Redis кластера для кеширования..."

# Функция для проверки готовности Redis
wait_for_redis() {
    local service=$1
    local max_attempts=30
    local attempt=0
    
    echo "⏳ Ожидание готовности $service..."
    
    while [ $attempt -lt $max_attempts ]; do
        if docker compose exec -T $service redis-cli ping >/dev/null 2>&1; then
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

echo "📋 Проверка статуса Redis сервисов..."
docker compose ps | grep redis

echo "⏳ Проверка готовности всех Redis узлов..."
wait_for_redis "redis-1"
wait_for_redis "redis-2" 
wait_for_redis "redis-3"
wait_for_redis "redis-4"
wait_for_redis "redis-5"
wait_for_redis "redis-6"

echo "🔧 Проверка существующего кластера..."

# Проверяем состояние кластера более надежно
cluster_check=$(docker compose exec -T redis-1 redis-cli -c set test_cluster_check "ok" 2>&1 || echo "cluster_down")

if [[ "$cluster_check" == *"CLUSTERDOWN"* ]] || [[ "$cluster_check" == *"cluster_down"* ]] || [[ "$cluster_check" == *"MOVED"* ]]; then
    echo "🔧 Кластер неисправен или не создан. Создание Redis кластера (3 masters + 3 slaves)..."
    
    # Сброс предыдущего состояния
    echo "🧹 Очистка предыдущей конфигурации кластера..."
    for node in redis-1 redis-2 redis-3 redis-4 redis-5 redis-6; do
        docker compose exec -T $node redis-cli cluster reset hard 2>/dev/null || true
    done
    
    sleep 5
    
    # Создание нового кластера
    docker compose exec -T redis-1 bash -c "
    echo 'yes' | redis-cli --cluster create \\
      173.17.0.40:6379 173.17.0.41:6379 173.17.0.42:6379 \\
      173.17.0.43:6379 173.17.0.44:6379 173.17.0.45:6379 \\
      --cluster-replicas 1
    "
else
    echo "✅ Redis кластер функционирует корректно"
    # Очистка тестового ключа
    docker compose exec -T redis-1 redis-cli -c del test_cluster_check >/dev/null 2>&1 || true
fi

echo "⏳ Ожидание готовности кластера..."
sleep 10

echo "✅ Проверка статуса кластера..."
echo "📋 Информация о узлах Redis кластера:"
docker compose exec -T redis-1 redis-cli cluster nodes

echo "📊 Информация о слотах (hash slots):"
docker compose exec -T redis-1 redis-cli cluster slots

echo "🧪 Тестирование кластера..."
echo "Запись тестового ключа..."
docker compose exec -T redis-1 redis-cli -c set test_key "Hello Redis Cluster!"

echo "Чтение тестового ключа..."
result=$(docker compose exec -T redis-1 redis-cli -c get test_key | tr -d '\r')
echo "Результат: $result"

if [ "$result" = "Hello Redis Cluster!" ]; then
    echo "✅ Redis кластер работает корректно!"
else
    echo "❌ Проблема с Redis кластером"
    exit 1
fi

echo "🧹 Очистка тестовых данных..."
docker compose exec -T redis-1 redis-cli -c del test_key

echo ""
echo "🎉 Redis кластер успешно инициализирован!"
echo ""
echo "📋 Конфигурация кластера:"
echo "• redis-1 (173.17.0.40:6379) - Master"
echo "• redis-2 (173.17.0.41:6379) - Master" 
echo "• redis-3 (173.17.0.42:6379) - Master"
echo "• redis-4 (173.17.0.43:6379) - Slave"
echo "• redis-5 (173.17.0.44:6379) - Slave"
echo "• redis-6 (173.17.0.45:6379) - Slave"
echo ""
echo "🔧 Кеширование готово к использованию!"
echo "🌐 Приложение с кешем доступно на http://localhost:8080"
echo ""
echo "🧪 Для тестирования кеширования:"
echo "time curl http://localhost:8080/helloDoc/users  # Cache Miss (медленно)"
echo "time curl http://localhost:8080/helloDoc/users  # Cache Hit (быстро <100мс)"
