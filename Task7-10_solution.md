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

# Задание 9. Настройка чтения с реплик и консистентность

## Обзор задачи
Определить стратегию чтения с primary и secondary реплик для коллекций `orders`, `products` и `carts` с учетом требований к консистентности и бизнес-логики.

## 1. Коллекция `orders` (Заказы)

### 1.1 Операции чтения только с PRIMARY

| Операция | Описание | Обоснование |
|----------|----------|-------------|
| Проверка статуса заказа пользователем | `db.orders.findOne({_id: orderId})` | Пользователь ожидает актуальный статус |
| Список активных заказов в ЛК | `db.orders.find({user_id: userId, status: {$nin: ["delivered", "cancelled"]}})` | Критично для UX |
| Проверка заказа перед оплатой | `db.orders.findOne({_id: orderId, status: "created"})` | Финансовая операция |
| Админ-панель: изменение статуса | `db.orders.findOne({_id: orderId})` перед update | Требует актуальных данных |

### 1.2 Операции чтения с SECONDARY

| Операция | Описание | Допустимая задержка |
|----------|----------|---------------------|
| История заказов (архив) | `db.orders.find({user_id: userId, status: "delivered"})` | 5-10 секунд |
| Аналитические отчеты | `db.orders.aggregate([...])` для статистики | 1-5 минут |
| Экспорт данных | Массовая выгрузка для отчетности | 5-10 минут |

**Обоснование:**
- Заказы обновляются относительно редко (при смене статуса)
- Критичность актуальности зависит от статуса заказа
- Архивные заказы не меняются

## 2. Коллекция `products` (Товары)

### 2.1 Операции чтения только с PRIMARY

| Операция | Описание | Обоснование |
|----------|----------|-------------|
| Проверка остатков перед добавлением в корзину | `db.products.findOne({_id: productId}, {stocks: 1})` | Избежать overselling |
| Страница товара с остатками | `db.products.findOne({_id: productId})` | Актуальная доступность |
| Обновление цены/остатков (админ) | Чтение перед изменением | Консистентность данных |

### 2.2 Операции чтения с SECONDARY

| Операция | Описание | Допустимая задержка |
|----------|----------|---------------------|
| Каталог товаров (список) | `db.products.find({category: "electronics"})` | 30-60 секунд |
| Поиск по названию | `db.products.find({$text: {$search: query}})` | 30-60 секунд |
| Рекомендации | `db.products.find({category: cat, _id: {$ne: currentId}})` | 1-5 минут |
| SEO страницы | Метаданные для поисковиков | 5-10 минут |

**Обоснование:**
- Остатки критичны и часто меняются
- Метаданные товаров (название, описание) меняются редко
- Для каталога важнее скорость, чем абсолютная актуальность

## 3. Коллекция `carts` (Корзины)

### 3.1 Операции чтения только с PRIMARY

| Операция | Описание | Обоснование |
|----------|----------|-------------|
| Получение активной корзины | `db.carts.findOne({owner_key: key, status: "active"})` | Все операции с корзиной |
| Проверка перед оформлением | Валидация содержимого | Критично для checkout |
| API добавления товара | Чтение → модификация → запись | Транзакционность |

### 3.2 Операции чтения с SECONDARY

| Операция | Описание | Допустимая задержка |
|----------|----------|---------------------|
| Брошенные корзины (маркетинг) | `db.carts.find({status: "abandoned"})` | 10-30 минут |
| Статистика корзин | Аналитика по конверсии | 1-5 минут |
| Очистка старых корзин | TTL мониторинг | 1 час |

**Обоснование:**
- Активные корзины постоянно обновляются
- Критична консистентность при checkout
- Аналитика может использовать слегка устаревшие данные


## 4. Сводная таблица допустимых задержек

| Коллекция | Тип операции | Read Preference | Макс. задержка | Обоснование |
|-----------|--------------|-----------------|----------------|-------------|
| **orders** | Активные заказы | Primary | 0 сек | Критично для UX |
| **orders** | История/архив | Secondary | 5-10 сек | Редко меняется |
| **products** | Остатки | Primary | 0 сек | Риск overselling |
| **products** | Каталог | Secondary | 30-60 сек | Баланс скорости/актуальности |
| **carts** | Активная корзина | Primary | 0 сек | Постоянные изменения |
| **carts** | Аналитика | Secondary | 10-30 мин | Некритичные данные |


## Заключение по заданию 9

Предложенная стратегия чтения обеспечивает:
- **Консистентность** для критичных операций (остатки, активные заказы)
- **Производительность** для массовых операций (каталог, аналитика)
- **Баланс** между нагрузкой на primary и актуальностью данных

Ключевой принцип: финансовые и инвентарные операции всегда с primary, аналитика и архивы - с secondary.

---

# Задание 10. Миграция на Cassandra: модель данных, стратегии репликации и шардирования

## Контекст проблемы
Во время Black Friday MongoDB с Range-Based Sharding показала критические проблемы:
- При 50,000 RPS добавление новых шардов вызывало полное перераспределение данных
- Просадка latency из-за ресурсов на миграцию чанков
- Необходимость в leaderless архитектуре для устойчивости

## Задание 10.1. Анализ данных для миграции в Cassandra

### Критически важные данные и их характеристики

| Сущность | Объем записей | Частота записи | Частота чтения | Критичность |
|----------|---------------|----------------|----------------|-------------|
| **Пользовательские сессии** | 10M активных | Очень высокая | Очень высокая | Высокая |
| **Корзины (активные)** | 2-3M | Высокая | Высокая | Высокая |
| **История просмотров** | 100M+/день | Очень высокая | Средняя | Средняя |
| **Заказы** | 1M/день | Средняя | Средняя | Высокая |
| **Товары** | 500K | Низкая | Очень высокая | Средняя |
| **Остатки товаров** | 500K×5 зон | Высокая | Высокая | Критическая |

### Рекомендации по миграции

#### ✅ ПЕРЕНОСИМ в Cassandra:

**1. Пользовательские сессии**
- Причины: Write-heavy, TTL native support, key-value паттерн
- Выгода: Линейное масштабирование записи

**2. История просмотров / Клики**
- Причины: Time-series данные, append-only, partitioning по времени
- Выгода: Эффективная ротация старых данных

**3. Корзины (активные)**
- Причины: Высокая нагрузка на запись/чтение, TTL для очистки
- Выгода: Быстрый доступ по ключу

**4. Кеш популярных товаров**
- Причины: Read-heavy, можно денормализовать
- Выгода: Low latency чтения

#### ❌ ОСТАВЛЯЕМ в MongoDB:

**1. Заказы**
- Причины: Нужны сложные запросы, транзакции, связи
- Риски в Cassandra: Нет JOIN, сложная аналитика

**2. Основной каталог товаров**
- Причины: Нужен полнотекстовый поиск, фильтры по множеству полей
- Риски в Cassandra: Только запросы по primary key

**3. Остатки товаров**
- Причины: Требуются атомарные операции декремента
- Риски в Cassandra: Eventual consistency может привести к overselling

## Задание 10.2. Модель данных для Cassandra

### 1. Таблица user_sessions

```sql
CREATE TABLE user_sessions (
    session_id UUID,
    user_id TEXT,
    created_at TIMESTAMP,
    last_activity TIMESTAMP,
    ip_address INET,
    user_agent TEXT,
    data MAP<TEXT, TEXT>,
    PRIMARY KEY (session_id)
) WITH default_time_to_live = 86400  -- 24 часа
  AND gc_grace_seconds = 3600;

-- Дополнительная таблица для поиска по user_id
CREATE TABLE sessions_by_user (
    user_id TEXT,
    created_at TIMESTAMP,
    session_id UUID,
    PRIMARY KEY (user_id, created_at)
) WITH CLUSTERING ORDER BY (created_at DESC)
  AND default_time_to_live = 86400;
```

**Обоснование:**
- Partition key `session_id` - равномерное распределение (UUID)
- TTL автоматически удаляет старые сессии
- Вторая таблица для запросов "все сессии пользователя"

### 2. Таблица view_history

```sql
CREATE TABLE view_history (
    user_id TEXT,
    view_date DATE,
    viewed_at TIMESTAMP,
    product_id TEXT,
    category TEXT,
    price DECIMAL,
    PRIMARY KEY ((user_id, view_date), viewed_at, product_id)
) WITH CLUSTERING ORDER BY (viewed_at DESC, product_id ASC)
  AND default_time_to_live = 2592000  -- 30 дней
  AND compaction = {
    'class': 'TimeWindowCompactionStrategy',
    'compaction_window_unit': 'DAYS',
    'compaction_window_size': '1'
  };
```

**Обоснование:**
- Composite partition key `(user_id, view_date)` - ограничивает размер партиции одним днем
- Clustering по времени - эффективные запросы последних просмотров
- TWCS для эффективного удаления старых данных

### 3. Таблица carts

```sql
CREATE TABLE carts (
    owner_key TEXT,  -- "u:user_id" или "s:session_id"
    updated_at TIMESTAMP,
    status TEXT,
    items LIST<FROZEN<cart_item>>,
    total DECIMAL,
    PRIMARY KEY (owner_key)
) WITH default_time_to_live = 604800;  -- 7 дней

-- UDT для элементов корзины
CREATE TYPE cart_item (
    product_id TEXT,
    quantity INT,
    price DECIMAL,
    name TEXT
);

-- Таблица для поиска брошенных корзин
CREATE TABLE abandoned_carts (
    abandonment_date DATE,
    abandoned_at TIMESTAMP,
    owner_key TEXT,
    total DECIMAL,
    PRIMARY KEY (abandonment_date, abandoned_at, owner_key)
) WITH CLUSTERING ORDER BY (abandoned_at DESC);
```

**Обоснование:**
- Simple partition key для быстрого доступа
- LIST для хранения товаров
- Отдельная таблица для аналитики брошенных корзин

### 4. Таблица popular_products_cache

```sql
CREATE TABLE popular_products_cache (
    category TEXT,
    popularity_rank INT,
    product_id TEXT,
    name TEXT,
    price DECIMAL,
    image_url TEXT,
    rating FLOAT,
    stock_status TEXT,
    PRIMARY KEY (category, popularity_rank, product_id)
) WITH CLUSTERING ORDER BY (popularity_rank ASC)
  AND default_time_to_live = 3600;  -- 1 час

-- Глобальный топ
CREATE TABLE global_popular_products (
    shard INT,  -- 0-9 для распределения нагрузки
    popularity_rank INT,
    product_id TEXT,
    data FROZEN<product_data>,
    PRIMARY KEY (shard, popularity_rank)
) WITH CLUSTERING ORDER BY (popularity_rank ASC);
```

**Обоснование:**
- Партиционирование по категории для целевых запросов
- Ранжирование через clustering key
- Шардирование глобального топа для избежания hot partition

## Задание 10.3. Стратегии обеспечения целостности данных

### Обзор стратегий Cassandra

| Стратегия | Описание | Когда срабатывает | Overhead |
|-----------|----------|-------------------|----------|
| **Hinted Handoff** | Временное хранение данных для недоступных узлов | При записи | Низкий |
| **Read Repair** | Синхронизация при обнаружении расхождений | При чтении | Средний |
| **Anti-Entropy Repair** | Полная проверка и восстановление | По расписанию | Высокий |

### Рекомендации по сущностям

#### 1. User Sessions
- **Write CL**: `ONE` (максимальная скорость)
- **Read CL**: `ONE` (не критично если потеряем)
- **Стратегии**: Только Hinted Handoff
- **Обоснование**: Сессии можно пересоздать, скорость важнее

#### 2. View History
- **Write CL**: `ANY` (fire-and-forget)
- **Read CL**: `ONE`
- **Стратегии**: Hinted Handoff + редкий Anti-Entropy (раз в неделю)
- **Обоснование**: Потеря части истории некритична

#### 3. Carts (Корзины)
- **Write CL**: `QUORUM` (важна консистентность)
- **Read CL**: `QUORUM`
- **Стратегии**: Все три (Hinted Handoff + Read Repair + Anti-Entropy daily)
- **Обоснование**: Критично для UX и конверсии

#### 4. Popular Products Cache
- **Write CL**: `ONE`
- **Read CL**: `ONE` 
- **Стратегии**: Только Hinted Handoff
- **Обоснование**: Кеш можно пересчитать

### Конфигурация repair стратегий

```yaml
# cassandra.yaml
hinted_handoff_enabled: true
max_hint_window_in_ms: 10800000  # 3 часа

# Read repair chances
read_repair_chance: 0.0  # Отключаем для сессий и кеша
dclocal_read_repair_chance: 0.1  # 10% для корзин

# Anti-entropy repair schedule (via cron)
# Корзины - ежедневно
0 2 * * * nodetool repair -pr keyspace carts
# История - еженедельно  
0 3 * * 0 nodetool repair -pr keyspace view_history
```

## Архитектурная схема миграции

```
┌────────────────────────────────────────────────────────────┐
│                    API Gateway                             │
└─────────────────┬─────────────────────┬────────────────────┘
                  │                     │
         ┌────────▼────────┐   ┌────────▼────────┐
         │   MongoDB       │   │   Cassandra     │
         │   Cluster       │   │   Cluster       │
         ├─────────────────┤   ├─────────────────┤
         │ • Orders        │   │ • Sessions      │
         │ • Products      │   │ • View History  │
         │ • Inventory     │   │ • Carts         │
         │                 │   │ • Popular Cache │
         └─────────────────┘   └─────────────────┘
         Strong Consistency    Eventual Consistency
         Complex Queries       High Write Throughput
```

## Заключение по заданию 10

Предложенная гибридная архитектура MongoDB + Cassandra позволит:

1. **Снизить нагрузку на MongoDB** - вынос 70% write операций в Cassandra
2. **Линейное масштабирование** - добавление узлов Cassandra без downtime
3. **Оптимальное использование БД** - каждая для своих задач
4. **Готовность к 100K+ RPS**

Ключевые решения:
- Сессии и история в Cassandra (write-heavy, TTL)
- Заказы и каталог в MongoDB (сложные запросы)
- Разные consistency levels для разных данных
- Минимальный repair overhead для некритичных данных

---