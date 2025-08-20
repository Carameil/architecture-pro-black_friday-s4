# Архитектурный документ: Решения заданий 7-10
## Шардирование, мониторинг и миграция MongoDB → Cassandra

---

# Задание 7. Проектирование схем коллекций для шардирования данных

## 1. Обзор архитектурного решения

Онлайн-магазин "Мобильный мир" расширился от аксессуаров до полноценного marketplace с электроникой, бытовой техникой и другими категориями. Проектируем шардированную архитектуру MongoDB с учетом:

- Паттернов доступа к данным каждой коллекции
- Предотвращения "горячих" шардов
- Минимизации cross-shard операций
- Поддержки геораспределенности

### Принципы выбора шард-ключей

1. **Распределение нагрузки**: избегаем монотонных ключей (например, `created_at` в одиночку)
2. **Маршрутизация запросов**: ключ должен совпадать с самыми частыми фильтрами равенства
3. **Иммутабельность**: не включаем изменяемые поля (например, статус) в шард-ключ
4. **Масштабируемость**: используем `hashed` для равномерности, `ranged` для диапазонных запросов

---

## 2. Схемы коллекций с валидацией

### 2.1 Коллекция `orders` (Заказы)

**JSON Schema валидация:**
```javascript
db.createCollection("orders", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "user_id", "created_at", "items", "status", "total", "geo_zone"],
      properties: {
        _id: { bsonType: "objectId" },
        user_id: { bsonType: "string", description: "ID пользователя" },
        created_at: { bsonType: "date" },
        items: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["product_id", "qty", "price"],
            properties: {
              product_id: { bsonType: "string" },
              qty: { bsonType: "int", minimum: 1 },
              price: { bsonType: "decimal" }
            }
          }
        },
        status: { 
          enum: ["created", "paid", "processing", "shipped", "delivered", "cancelled"],
          description: "Статус заказа"
        },
        total: { bsonType: "decimal", minimum: 0 },
        geo_zone: { 
          bsonType: "string",
          enum: ["moscow", "spb", "ekaterinburg", "novosibirsk", "kaliningrad"]
        }
      }
    }
  }
});
```

**Пример документа:**
```javascript
{
  _id: ObjectId("64f5a2b3c4e5d6f7a8b9c0d1"),
  user_id: "usr_123456",
  created_at: ISODate("2024-08-18T10:30:00Z"),
  items: [
    {
      product_id: "PROD-IPHONE15-PRO",
      qty: 1,
      price: NumberDecimal("89990.00"),
      name: "iPhone 15 Pro 256GB"
    }
  ],
  status: "processing",
  total: NumberDecimal("89990.00"),
  geo_zone: "moscow",
  shipping_address: {
    city: "Москва",
    street: "Тверская ул., 15",
    postal_code: "125009"
  },
  payment_method: "card",
  delivery_date: ISODate("2024-08-20T14:00:00Z")
}
```

### 2.2 Коллекция `products` (Товары)

**JSON Schema валидация:**
```javascript
db.createCollection("products", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "name", "category", "price", "stocks"],
      properties: {
        _id: { 
          bsonType: "string",
          description: "SKU или артикул как стабильный ID"
        },
        name: { bsonType: "string" },
        category: { 
          bsonType: "string",
          enum: ["electronics", "appliances", "accessories", "books", "clothing", "home"]
        },
        price: { bsonType: "decimal", minimum: 0 },
        attributes: { 
          bsonType: "object",
          description: "Цвет, размер, вес и т.д."
        },
        stocks: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["geo_zone", "qty", "updated_at"],
            properties: {
              geo_zone: { bsonType: "string" },
              qty: { bsonType: "int", minimum: 0 },
              warehouse_id: { bsonType: "string" },
              updated_at: { bsonType: "date" }
            }
          }
        }
      }
    }
  }
});
```

**Пример документа:**
```javascript
{
  _id: "PROD-IPHONE15-PRO-256",
  name: "iPhone 15 Pro 256GB",
  category: "electronics",
  subcategory: "smartphones",
  brand: "Apple",
  price: NumberDecimal("89990.00"),
  attributes: {
    color: "Natural Titanium",
    storage: "256GB",
    display_size: "6.1 inch",
    weight: "187g"
  },
  stocks: [
    { geo_zone: "moscow", qty: 150, warehouse_id: "WH-MSK-01", updated_at: ISODate("2024-08-18T09:00:00Z") },
    { geo_zone: "spb", qty: 89, warehouse_id: "WH-SPB-01", updated_at: ISODate("2024-08-18T09:00:00Z") },
    { geo_zone: "ekaterinburg", qty: 50, warehouse_id: "WH-EKB-01", updated_at: ISODate("2024-08-18T08:00:00Z") }
  ],
  rating: 4.8,
  reviews_count: 1250
}
```

### 2.3 Коллекция `carts` (Корзины)

Для решения проблемы с гостевыми и авторизованными корзинами вводим поле `owner_key`:
- Для гостя: `owner_key = "s:" + session_id`
- Для пользователя: `owner_key = "u:" + user_id`

**JSON Schema валидация:**
```javascript
db.createCollection("carts", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "status", "created_at", "updated_at", "expires_at", "items", "owner_key"],
      properties: {
        _id: { bsonType: "objectId" },
        user_id: { bsonType: ["string", "null"] },
        session_id: { bsonType: ["string", "null"] },
        owner_key: { 
          bsonType: "string",
          pattern: "^(u:|s:)",
          description: "u:user_id или s:session_id"
        },
        status: { enum: ["active", "ordered", "abandoned", "merged"] },
        items: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["product_id", "quantity"],
            properties: {
              product_id: { bsonType: "string" },
              quantity: { bsonType: "int", minimum: 1 },
              added_at: { bsonType: "date" }
            }
          }
        },
        created_at: { bsonType: "date" },
        updated_at: { bsonType: "date" },
        expires_at: { bsonType: "date" }
      }
    }
  }
});
```

**Пример документа:**
```javascript
{
  _id: ObjectId("64f5a2b3c4e5d6f7a8b9c0d2"),
  user_id: "usr_123456",
  session_id: null,
  owner_key: "u:usr_123456",  // Унифицированный ключ
  status: "active",
  items: [
    {
      product_id: "PROD-IPHONE15-PRO-256",
      quantity: 1,
      price: NumberDecimal("89990.00"),
      added_at: ISODate("2024-08-18T10:15:00Z")
    }
  ],
  total: NumberDecimal("89990.00"),
  created_at: ISODate("2024-08-18T10:15:00Z"),
  updated_at: ISODate("2024-08-18T10:20:00Z"),
  expires_at: ISODate("2024-08-25T10:15:00Z")
}
```

---

## 3. Выбор стратегий шардирования

### 3.1 Коллекция `orders`

**Выбранный шард-ключ:** `{ user_id: "hashed", created_at: 1 }`

**Тип:** Compound-hashed (составной с хешированием)

**Обоснование:**
- ✅ **Локальность запросов**: История заказов пользователя - на одном шарде
- ✅ **Равномерное распределение**: Хеширование user_id предотвращает горячие шарды
- ✅ **Временные диапазоны**: created_at позволяет эффективные запросы по периодам внутри пользователя
- ✅ **Масштабируемость**: Новые заказы равномерно распределяются

**Альтернативы и почему отклонены:**
1. **`{ geo_zone: 1, created_at: 1 }`** - Неравномерность (Москва >> Калининград)
2. **`{ created_at: 1 }`** - Монотонный ключ, горячий шард для новых заказов
3. **`{ order_id: "hashed" }`** - Cross-shard для истории пользователя

### 3.2 Коллекция `products`

**Выбранный шард-ключ:** `{ category: 1, _id: "hashed" }`

**Тип:** Compound (range prefix + hash)

**Обоснование:**
- ✅ **Таргетированные запросы**: Поиск по категории попадает на конкретные шарды
- ✅ **Избежание горячих категорий**: Хеш по _id распределяет товары внутри категории
- ✅ **Эффективная фильтрация**: Запросы с category + price используют префикс
- ✅ **Предотвращение дисбаланса**: "Электроника" не создаст горячий шард

**Альтернативы и почему отклонены:**
1. **`{ category: 1 }`** - 70% нагрузки на шард "electronics"
2. **`{ _id: "hashed" }`** - Все каталожные запросы становятся scatter-gather
3. **`{ brand: 1 }`** - Apple/Samsung создадут горячие шарды

### 3.3 Коллекция `carts`

**Выбранный шард-ключ:** `{ owner_key: "hashed" }`

**Тип:** Hashed

**Обоснование:**
- ✅ **Унификация**: Один подход для гостей и пользователей
- ✅ **Точечные операции**: Все операции с корзиной на одном шарде
- ✅ **Простота слияния**: При логине знаем оба owner_key
- ✅ **Равномерность**: Хеширование обеспечивает распределение

**Инновация - owner_key:**
```javascript
// Гостевая корзина
{ owner_key: "s:sess_abc123", session_id: "sess_abc123", user_id: null }

// Пользовательская корзина  
{ owner_key: "u:usr_123456", user_id: "usr_123456", session_id: null }
```

---

## 4. Диаграмма распределения данных

```
┌─────────────────────────────────────────────────────────────────────┐
│                     MongoDB Sharded Cluster                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌───────────────┐    ┌───────────────┐    ┌───────────────┐        │
│  │   Shard 1     │    │   Shard 2     │    │   Shard 3     │        │
│  ├───────────────┤    ├───────────────┤    ├───────────────┤        │
│  │ orders:       │    │ orders:       │    │ orders:       │        │
│  │ user_id hash  │    │ user_id hash  │    │ user_id hash  │        │
│  │ [0x0-0x555]   │    │ [0x556-0xAAA] │    │ [0xAAB-0xFFF] │        │
│  ├───────────────┤    ├───────────────┤    ├───────────────┤        │
│  │ products:     │    │ products:     │    │ products:     │        │
│  │ electronics + │    │ appliances +  │    │ accessories + │        │
│  │ hash ranges   │    │ books + hash  │    │ home + hash   │        │
│  ├───────────────┤    ├───────────────┤    ├───────────────┤        │
│  │ carts:        │    │ carts:        │    │ carts:        │        │
│  │ owner_key     │    │ owner_key     │    │ owner_key     │        │
│  │ [0x0-0x555]   │    │ [0x556-0xAAA] │    │ [0xAAB-0xFFF] │        │
│  └───────────────┘    └───────────────┘    └───────────────┘        │
│                                                                     │
│                    ┌─────────────────────┐                          │
│                    │   Config Servers    │                          │
│                    │   (3x Replica Set)  │                          │
│                    └─────────────────────┘                          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 5. Оптимизация для высоких нагрузок на остатки

При интенсивных обновлениях остатков товаров рекомендуется вынести inventory в отдельную коллекцию:

```javascript
// Отдельная коллекция для остатков
db.createCollection("inventory", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["product_id", "geo_zone", "qty", "warehouse_id"],
      properties: {
        product_id: { bsonType: "string" },
        geo_zone: { bsonType: "string" },
        qty: { bsonType: "int", minimum: 0 },
        warehouse_id: { bsonType: "string" },
        reserved: { bsonType: "int", default: 0 },
        updated_at: { bsonType: "date" }
      }
    }
  }
});

// Шардирование по геозоне для локальности обновлений
sh.shardCollection("mobilnymir.inventory", {
  geo_zone: 1,
  product_id: "hashed"
});
```

---

## 6. Сводная таблица решений

| Коллекция | Шард-ключ | Метод | Обоснование |
|-----------|-----------|-------|-------------|
| **orders** | `{user_id: "hashed", created_at: 1}` | Compound-hashed | Равномерность + история пользователя + временные запросы |
| **products** | `{category: 1, _id: "hashed"}` | Range prefix + hash | Таргетированные каталожные запросы + избежание горячих категорий |
| **carts** | `{owner_key: "hashed"}` | Hashed | Унификация гостей/пользователей + точечные операции |


---

## Заключение по заданию 7

Спроектированная архитектура шардирования обеспечивает:

1. **Оптимальные шард-ключи** для каждой коллекции на основе паттернов доступа
2. **Предотвращение горячих шардов** через составные ключи и хеширование
3. **Эффективные операции** - большинство запросов являются targeted
4. **Готовность к масштабированию** для нагрузок Black Friday

Ключевые инновации:
- Составной ключ для orders сохраняет временную локальность
- Products использует префикс категории для оптимизации каталожных запросов
- Унифицированный owner_key решает проблему гостевых корзин

---

# Задание 8. Выявление и устранение «горячих» шардов

## Проблема
Категория "Электроника" создала перегрузку одного из шардов MongoDB - 70% запросов приходится на эти товары. Необходимо разработать стратегию мониторинга и устранения горячих шардов.

## 1. Метрики для отслеживания состояния шардов

### 1.1 Базовые метрики распределения данных

```javascript
// Проверка распределения документов по шардам
db.products.getShardDistribution()

// Пример вывода:
// Shard shard01 at shard01/localhost:27018
//  data : 2.5GB docs : 150000 chunks : 45
// Shard shard02 at shard02/localhost:27019  
//  data : 8.2GB docs : 520000 chunks : 156  // ⚠️ Горячий шард!
// Shard shard03 at shard03/localhost:27020
//  data : 2.1GB docs : 130000 chunks : 39
```

### 1.2 Метрики нагрузки на шарды

```javascript
// Статистика операций по шардам
db.adminCommand({ 
  shardConnPoolStats: 1 
})

// Мониторинг количества запросов
db.runCommand({ 
  collStats: "products", 
  indexDetails: true 
})
```

### 1.3 Скрипт для регулярного мониторинга

```javascript
// Скрипт для выявления дисбаланса
function checkShardBalance() {
  const stats = db.products.getShardDistribution();
  const shards = [];
  
  // Парсинг статистики (псевдокод)
  stats.forEach(shard => {
    shards.push({
      name: shard.name,
      docs: shard.documentCount,
      size: shard.dataSize
    });
  });
  
  // Вычисление среднего
  const avgDocs = shards.reduce((sum, s) => sum + s.docs, 0) / shards.length;
  
  // Проверка отклонения
  shards.forEach(shard => {
    const deviation = Math.abs(shard.docs - avgDocs) / avgDocs * 100;
    if (deviation > 30) {
      print(`WARNING: Shard ${shard.name} has ${deviation}% deviation!`);
    }
  });
}
```

## 2. Механизмы устранения дисбаланса

### 2.1 Перенастройка балансировщика

```javascript
// Включение балансировщика
sh.setBalancerState(true)

// Настройка окна балансировки (ночные часы)
db.settings.update(
   { _id: "balancer" },
   { $set: { activeWindow : { start : "23:00", stop : "06:00" } } },
   { upsert: true }
)

// Уменьшение размера чанков для лучшего распределения
use config
db.settings.save({
  _id: "chunksize",
  value: 32  // МБ вместо стандартных 64
})
```

### 2.2 Ручное перераспределение данных

```javascript
// Для категории "electronics" - разделение на подкатегории
// Добавляем поле subcategory для более детального разделения
db.products.updateMany(
  { category: "electronics" },
  { $set: { 
    subcategory: { 
      $switch: {
        branches: [
          { case: { $regex: /phone|smartphone/i }, then: "smartphones" },
          { case: { $regex: /laptop|notebook/i }, then: "laptops" },
          { case: { $regex: /tv|television/i }, then: "tvs" }
        ],
        default: "other_electronics"
      }
    }
  }}
)

// Миграция на новый составной ключ
sh.shardCollection("mobilnymir.products_v2", {
  category: 1,
  subcategory: 1,
  _id: "hashed"
})
```

### 2.3 Настройка chunk migration

```javascript
// Принудительное разделение больших чанков
sh.splitFind("mobilnymir.products", { category: "electronics" })

// Перемещение чанков вручную
sh.moveChunk("mobilnymir.products", 
  { category: "electronics", _id: MinKey },
  "shard03"  // Менее загруженный шард
)
```

## 3. Превентивные меры

### 3.1 Алерты для раннего обнаружения

```javascript
// Настройка порогов для мониторинга
const thresholds = {
  maxDeviationPercent: 30,    // Максимальное отклонение от среднего
  maxChunksPerShard: 200,      // Максимум чанков на шард
  maxSizeGBPerShard: 10        // Максимальный размер данных
};

// Функция проверки (запускать по cron)
function checkShardHealth() {
  const dist = db.products.getShardDistribution();
  // Логика проверки порогов
  // Отправка алертов при превышении
}
```

### 3.2 Оптимизация для популярных категорий

```javascript
// Создание отдельной коллекции для горячих данных
db.createCollection("hot_products");

// Вынос популярных товаров
db.products.find({ 
  category: "electronics", 
  views: { $gt: 10000 } 
}).forEach(doc => {
  db.hot_products.insert(doc);
});

// Шардирование с учетом популярности
sh.shardCollection("mobilnymir.hot_products", {
  popularity_score: 1,
  _id: "hashed"
});
```

## 4. Рекомендации по настройке

1. **Регулярный мониторинг**: Запускать проверку баланса каждые 4 часа
2. **Автоматическая балансировка**: Включить в ночные часы для минимизации влияния на производительность
3. **Размер чанков**: Уменьшить до 32MB для лучшей гранулярности
4. **Превентивное разделение**: Для категорий с ростом > 20% в месяц

## Заключение по заданию 8

Предложенная система мониторинга и балансировки позволит:
- Своевременно выявлять горячие шарды через метрики отклонения
- Автоматически перераспределять нагрузку через балансировщик
- Предотвращать будущие проблемы через превентивные меры

Ключевое решение для "Электроники" - введение subcategory в шард-ключ для более детального распределения популярной категории.

---