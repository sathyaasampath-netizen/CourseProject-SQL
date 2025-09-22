-- FoodExpress: On-Demand Food Delivery Database (MySQL 8.0+)
-- Creates tables, constraints, indexes, views, triggers, and stored procedures.

DROP DATABASE IF EXISTS FoodExpressDB;
CREATE DATABASE FoodExpressDB CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE FoodExpressDB;

-- Users
CREATE TABLE users (
  user_id INT PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL,
  email VARCHAR(120) NOT NULL UNIQUE,
  phone VARCHAR(20),
  role ENUM('customer','restaurant_owner','courier','admin') NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Customers (1:1 with users)
CREATE TABLE customers (
  customer_id INT PRIMARY KEY,
  loyalty_status ENUM('Bronze','Silver','Gold','Platinum') NOT NULL DEFAULT 'Bronze',
  preferences_json JSON,
  CONSTRAINT fk_customer_user FOREIGN KEY (customer_id) REFERENCES users(user_id)
);

-- Addresses (1:M from customers)
CREATE TABLE addresses (
  address_id INT PRIMARY KEY,
  customer_id INT NOT NULL,
  address_line VARCHAR(120) NOT NULL,
  city VARCHAR(60) NOT NULL,
  province VARCHAR(10) NOT NULL,
  postal_code VARCHAR(10) NOT NULL,
  country VARCHAR(60) NOT NULL,
  latitude DECIMAL(9,6),
  longitude DECIMAL(9,6),
  is_default TINYINT NOT NULL DEFAULT 0,
  CONSTRAINT fk_addr_customer FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);
CREATE INDEX idx_addresses_customer ON addresses(customer_id);

-- Restaurants
CREATE TABLE restaurants (
  restaurant_id INT PRIMARY KEY,
  owner_user_id INT NOT NULL,
  name VARCHAR(120) NOT NULL,
  cuisine_type VARCHAR(40) NOT NULL,
  phone VARCHAR(20),
  city VARCHAR(60),
  rating_avg DECIMAL(3,2),
  hours_json JSON,
  CONSTRAINT fk_rest_owner FOREIGN KEY (owner_user_id) REFERENCES users(user_id)
);

-- Menus (1:M from restaurants)
CREATE TABLE menus (
  menu_id INT PRIMARY KEY,
  restaurant_id INT NOT NULL,
  title VARCHAR(80) NOT NULL,
  is_active TINYINT NOT NULL DEFAULT 1,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_menu_rest FOREIGN KEY (restaurant_id) REFERENCES restaurants(restaurant_id)
);
CREATE INDEX idx_menus_rest ON menus(restaurant_id);

-- Menu items (1:M from menus)
CREATE TABLE menu_items (
  item_id INT PRIMARY KEY,
  menu_id INT NOT NULL,
  name VARCHAR(120) NOT NULL,
  description VARCHAR(255),
  price DECIMAL(8,2) NOT NULL,
  calories INT,
  is_veg TINYINT NOT NULL DEFAULT 0,
  allergens_json JSON,
  CONSTRAINT fk_item_menu FOREIGN KEY (menu_id) REFERENCES menus(menu_id)
);
CREATE INDEX idx_items_menu ON menu_items(menu_id);
-- Fulltext for search
CREATE FULLTEXT INDEX ftx_menu_items_name_desc ON menu_items(name, description);

-- Couriers
CREATE TABLE couriers (
  courier_id INT PRIMARY KEY,
  user_id INT NOT NULL,
  vehicle_type ENUM('Bike','Car','Scooter') NOT NULL,
  license_no VARCHAR(40) NOT NULL UNIQUE,
  hired_at DATE,
  is_active TINYINT NOT NULL DEFAULT 1,
  CONSTRAINT fk_courier_user FOREIGN KEY (user_id) REFERENCES users(user_id)
);

-- Orders
CREATE TABLE orders (
  order_id INT PRIMARY KEY,
  customer_id INT NOT NULL,
  restaurant_id INT NOT NULL,
  address_id INT NOT NULL,
  order_time DATETIME NOT NULL,
  status ENUM('placed','preparing','out_for_delivery','delivered','cancelled') NOT NULL,
  subtotal DECIMAL(10,2) NOT NULL,
  tax DECIMAL(10,2) NOT NULL,
  delivery_fee DECIMAL(10,2) NOT NULL,
  total DECIMAL(10,2) NOT NULL,
  special_instructions TEXT,
  CONSTRAINT fk_order_customer FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
  CONSTRAINT fk_order_rest FOREIGN KEY (restaurant_id) REFERENCES restaurants(restaurant_id),
  CONSTRAINT fk_order_addr FOREIGN KEY (address_id) REFERENCES addresses(address_id),
  CONSTRAINT chk_total_nonneg CHECK (total >= 0.00)
);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_rest ON orders(restaurant_id);
CREATE INDEX idx_orders_time ON orders(order_time);

-- Order items (composite PK)
CREATE TABLE order_items (
  order_id INT NOT NULL,
  item_id INT NOT NULL,
  quantity INT NOT NULL,
  unit_price DECIMAL(8,2) NOT NULL,
  line_total DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (order_id, item_id),
  CONSTRAINT fk_oi_order FOREIGN KEY (order_id) REFERENCES orders(order_id) ON DELETE CASCADE,
  CONSTRAINT fk_oi_item FOREIGN KEY (item_id) REFERENCES menu_items(item_id),
  CONSTRAINT chk_qty CHECK (quantity > 0)
);

-- Payments (1:1 with orders)
CREATE TABLE payments (
  payment_id INT PRIMARY KEY,
  order_id INT NOT NULL UNIQUE,
  method ENUM('card','wallet','cash','upi') NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  status ENUM('paid','refunded','pending') NOT NULL,
  transaction_json JSON,
  CONSTRAINT fk_payment_order FOREIGN KEY (order_id) REFERENCES orders(order_id)
);

-- Deliveries (1:1 with orders)
CREATE TABLE deliveries (
  delivery_id INT PRIMARY KEY,
  order_id INT NOT NULL UNIQUE,
  courier_id INT NOT NULL,
  pickup_time DATETIME,
  dropoff_time DATETIME,
  status ENUM('assigned','picked_up','delivered','failed') NOT NULL,
  distance_km DECIMAL(6,2),
  shipping_label_xml TEXT,
  CONSTRAINT fk_delivery_order FOREIGN KEY (order_id) REFERENCES orders(order_id),
  CONSTRAINT fk_delivery_courier FOREIGN KEY (courier_id) REFERENCES couriers(courier_id)
);

-- Reviews
CREATE TABLE reviews (
  review_id INT PRIMARY KEY,
  order_id INT NOT NULL,
  customer_id INT NOT NULL,
  restaurant_id INT NOT NULL,
  rating INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comments VARCHAR(255),
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  sentiment_json JSON,
  CONSTRAINT fk_rev_order FOREIGN KEY (order_id) REFERENCES orders(order_id) ON DELETE CASCADE,
  CONSTRAINT fk_rev_customer FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
  CONSTRAINT fk_rev_rest FOREIGN KEY (restaurant_id) REFERENCES restaurants(restaurant_id)
);
CREATE INDEX idx_reviews_rest ON reviews(restaurant_id);
CREATE INDEX idx_reviews_customer ON reviews(customer_id);

-- ---------------- Triggers ----------------

-- Keep orders.subtotal/total in sync after adding/removing order_items
DELIMITER //
CREATE TRIGGER trg_order_items_after_ins
AFTER INSERT ON order_items
FOR EACH ROW
BEGIN
  UPDATE orders o
  JOIN (
    SELECT order_id, SUM(line_total) AS s FROM order_items WHERE order_id = NEW.order_id
  ) x ON o.order_id = x.order_id
  SET o.subtotal = x.s, o.tax = ROUND(x.s * 0.13, 2), o.total = ROUND(x.s * 1.13 + o.delivery_fee, 2);
END//
CREATE TRIGGER trg_order_items_after_del
AFTER DELETE ON order_items
FOR EACH ROW
BEGIN
  UPDATE orders o
  LEFT JOIN (
    SELECT order_id, SUM(line_total) AS s FROM order_items WHERE order_id = OLD.order_id
  ) x ON o.order_id = x.order_id
  SET o.subtotal = COALESCE(x.s,0), o.tax = ROUND(COALESCE(x.s,0) * 0.13, 2), o.total = ROUND(COALESCE(x.s,0) * 1.13 + o.delivery_fee, 2)
  WHERE o.order_id = OLD.order_id;
END//
DELIMITER ;

-- Auto-update restaurants.rating_avg when a review is inserted
DELIMITER //
CREATE TRIGGER trg_reviews_after_ins
AFTER INSERT ON reviews
FOR EACH ROW
BEGIN
  UPDATE restaurants r
  JOIN (
    SELECT restaurant_id, AVG(rating) AS avg_rating
    FROM reviews
    WHERE restaurant_id = NEW.restaurant_id
  ) t ON r.restaurant_id = t.restaurant_id
  SET r.rating_avg = ROUND(t.avg_rating, 2);
END//
DELIMITER ;

-- ---------------- Stored Procedure ----------------

DELIMITER //
CREATE PROCEDURE sp_place_order(
  IN p_customer_id INT,
  IN p_restaurant_id INT,
  IN p_address_id INT,
  IN p_items_json JSON   -- e.g., '[{"item_id": 4010, "qty": 2},{"item_id":4011,"qty":1}]'
)
BEGIN
  DECLARE v_order_id INT;
  DECLARE v_delivery_fee DECIMAL(10,2) DEFAULT 3.99;
  DECLARE v_subtotal DECIMAL(10,2) DEFAULT 0.00;
  DECLARE v_tax DECIMAL(10,2) DEFAULT 0.00;
  DECLARE v_total DECIMAL(10,2) DEFAULT 0.00;

  INSERT INTO orders(order_id, customer_id, restaurant_id, address_id, order_time, status, subtotal, tax, delivery_fee, total)
  VALUES (
    (SELECT IFNULL(MAX(order_id),6000) + 1 FROM orders),
    p_customer_id, p_restaurant_id, p_address_id, NOW(), 'placed', 0.00, 0.00, v_delivery_fee, 0.00
  );
  SET v_order_id = LAST_INSERT_ID();

  -- Insert order_items using JSON_TABLE
  INSERT INTO order_items(order_id, item_id, quantity, unit_price, line_total)
  SELECT v_order_id, mi.item_id, jt.qty, mi.price, ROUND(mi.price * jt.qty, 2)
  FROM JSON_TABLE(p_items_json, '$[*]' COLUMNS(item_id INT PATH '$.item_id', qty INT PATH '$.qty')) AS jt
  JOIN menu_items mi ON mi.item_id = jt.item_id;

  -- Totals (trigger will also handle this; this is a safeguard)
  SELECT SUM(line_total) INTO v_subtotal FROM order_items WHERE order_id = v_order_id;
  SET v_tax = ROUND(v_subtotal * 0.13, 2);
  SET v_total = ROUND(v_subtotal + v_tax + v_delivery_fee, 2);
  UPDATE orders SET subtotal = v_subtotal, tax = v_tax, total = v_total WHERE order_id = v_order_id;

  -- Create pending payment
  INSERT INTO payments(payment_id, order_id, method, amount, status, transaction_json)
  VALUES ((SELECT IFNULL(MAX(payment_id),9000) + 1 FROM payments), v_order_id, 'card', v_total, 'pending', JSON_OBJECT('created_by','sp_place_order'));

  SELECT v_order_id AS new_order_id;
END//
DELIMITER ;

-- ---------------- Views ----------------
CREATE OR REPLACE VIEW v_customer_order_summary AS
SELECT 
  c.customer_id,
  u.full_name,
  COUNT(o.order_id) AS total_orders,
  SUM(o.total) AS total_spent,
  AVG(o.total) AS avg_order_value,
  SUM(CASE WHEN o.status = 'delivered' THEN 1 ELSE 0 END) AS delivered_orders
FROM customers c
JOIN users u ON u.user_id = c.customer_id
LEFT JOIN orders o ON o.customer_id = c.customer_id
GROUP BY c.customer_id, u.full_name;

CREATE OR REPLACE VIEW v_restaurant_performance AS
SELECT 
  r.restaurant_id,
  r.name AS restaurant_name,
  COUNT(o.order_id) AS orders_count,
  SUM(o.total) AS revenue,
  AVG(rv.rating) AS avg_rating
FROM restaurants r
LEFT JOIN orders o ON o.restaurant_id = r.restaurant_id
LEFT JOIN reviews rv ON rv.restaurant_id = r.restaurant_id
GROUP BY r.restaurant_id, r.name;

-- --- DATASET 1 CUSTOMER BEHAVIOUR-----
CREATE OR REPLACE VIEW ML_Customer_Retention_Dataset AS
WITH last_order AS (
  SELECT o.customer_id, MAX(o.order_time) AS last_order_time
  FROM orders o
  GROUP BY o.customer_id
),
order_agg AS (
  SELECT 
      o.customer_id,
      COUNT(*)                                           AS total_orders,
      SUM(o.total)                                       AS total_spent,
      SUM(o.status = 'delivered')                        AS delivered_orders,
      SUM(o.status = 'cancelled')                        AS cancelled_orders
  FROM orders o
  GROUP BY o.customer_id
),
feedback AS (
  SELECT r.customer_id, COALESCE(AVG(r.rating), 0) AS avg_feedback_rating
  FROM reviews r
  GROUP BY r.customer_id
),
payment_pref AS (
  SELECT 
      o.customer_id,
      JSON_UNQUOTE(JSON_EXTRACT(p.transaction_json,'$.method')) AS pay_method
  FROM payments p
  JOIN orders o ON o.order_id = p.order_id
),
payment_mix AS (
  SELECT 
      customer_id,
      SUM(pay_method = 'card')   / COUNT(*) AS pm_card_share,
      SUM(pay_method = 'wallet') / COUNT(*) AS pm_wallet_share,
      SUM(pay_method = 'cash')   / COUNT(*) AS pm_cash_share
  FROM payment_pref
  GROUP BY customer_id
),
tracking_flags AS (
  SELECT 
      o.customer_id,
      AVG(
        CASE 
          WHEN REGEXP_SUBSTR(d.shipping_label_xml,'<trackingNumber>[^<]+</trackingNumber>') IS NULL 
          THEN 0 ELSE 1 
        END
      ) AS tracking_share
  FROM deliveries d
  JOIN orders o ON o.order_id = d.order_id
  GROUP BY o.customer_id
)
SELECT
  c.customer_id,

  -- Demographic / profile features (account age, basic prefs)
  DATEDIFF(CURDATE(), u.created_at)                           AS days_as_customer,
  CAST(JSON_EXTRACT(c.preferences_json, '$.spicy') AS UNSIGNED)       AS likes_spicy,
  JSON_LENGTH(JSON_EXTRACT(c.preferences_json, '$.favorite_cuisines')) AS favorite_cuisines_count,

  -- Behavioral features
  oa.total_orders,
  oa.delivered_orders,
  oa.cancelled_orders,

  -- Satisfaction features
  fb.avg_feedback_rating,

  -- Financial features
  oa.total_spent,
  COALESCE(pm.pm_card_share,   0) AS pm_card_share,
  COALESCE(pm.pm_wallet_share, 0) AS pm_wallet_share,
  COALESCE(pm.pm_cash_share,   0) AS pm_cash_share,

  -- Fulfillment signal (from XML label presence)
  COALESCE(tf.tracking_share,  0) AS tracking_share,

  -- Target variable (activity-based retention category)
  CASE
    WHEN oa.total_orders = 0         THEN 'Inactive'
    WHEN oa.total_orders < 5         THEN 'Low_Activity'
    WHEN oa.total_orders < 15        THEN 'Medium_Activity'
    ELSE                                  'High_Activity'
  END AS retention_category,

  -- Convenience flag (recent activity window)
  CASE
    WHEN DATEDIFF(CURDATE(), lo.last_order_time) <= 60 THEN 1 ELSE 0
  END AS is_active_recent_60d

FROM customers c
JOIN users u          ON u.user_id = c.customer_id
LEFT JOIN order_agg oa    ON oa.customer_id = c.customer_id
LEFT JOIN last_order lo   ON lo.customer_id = c.customer_id
LEFT JOIN feedback fb     ON fb.customer_id = c.customer_id
LEFT JOIN payment_mix pm  ON pm.customer_id = c.customer_id
LEFT JOIN tracking_flags tf ON tf.customer_id = c.customer_id;
 

-- --- DATASET2 - RESTAURENT PERFORMANCE----

CREATE OR REPLACE VIEW ML_Delivery_Performance_Dataset AS
WITH base AS (
  SELECT
      d.delivery_id,
      o.order_id,
      o.restaurant_id,
      d.courier_id,

      -- Targets
      TIMESTAMPDIFF(MINUTE, d.pickup_time, d.dropoff_time) AS minutes_to_deliver,
      (d.status = 'failed') AS failed_flag,

      -- Time features
      o.order_time,
      HOUR(o.order_time) AS order_hour,
      DAYOFWEEK(o.order_time) AS order_dow,
      (DAYOFWEEK(o.order_time) IN (1,7)) AS is_weekend,
      (HOUR(o.order_time) BETWEEN 11 AND 14
       OR HOUR(o.order_time) BETWEEN 18 AND 21) AS is_peak,

      -- Ops features
      TIMESTAMPDIFF(MINUTE, o.order_time, d.pickup_time) AS prep_minutes,
      c.vehicle_type,
      r.name AS restaurant_name,

      -- XML tracking signal
      CASE
        WHEN REGEXP_SUBSTR(d.shipping_label_xml,'<trackingNumber>[^<]+</trackingNumber>') IS NULL
        THEN 0 ELSE 1
      END AS has_tracking
  FROM deliveries d
  JOIN orders o      ON o.order_id = d.order_id
  JOIN couriers c    ON c.courier_id = d.courier_id
  JOIN restaurants r ON r.restaurant_id = o.restaurant_id
),
rest_30 AS (
  SELECT
      restaurant_id,
      AVG(TIMESTAMPDIFF(MINUTE, d.pickup_time, d.dropoff_time)) AS rest_avg_minutes_30d,
      AVG((d.status = 'failed'))                                  AS rest_fail_rate_30d
  FROM deliveries d
  JOIN orders o ON o.order_id = d.order_id
  WHERE o.order_time >= (CURDATE() - INTERVAL 30 DAY)
  GROUP BY restaurant_id
),
courier_30 AS (
  SELECT
      d.courier_id,
      AVG(TIMESTAMPDIFF(MINUTE, d.pickup_time, d.dropoff_time)) AS courier_avg_minutes_30d,
      AVG((d.status = 'failed'))                                  AS courier_fail_rate_30d
  FROM deliveries d
  JOIN orders o ON o.order_id = d.order_id
  WHERE o.order_time >= (CURDATE() - INTERVAL 30 DAY)
  GROUP BY d.courier_id
)
SELECT
    b.delivery_id,
    b.order_id,
    b.restaurant_id,
    b.courier_id,

    -- targets
    b.minutes_to_deliver,
    b.failed_flag,

    -- engineered features
    b.order_hour,
    b.order_dow,
    b.is_weekend,
    b.is_peak,
    b.prep_minutes,
    b.vehicle_type,
    b.has_tracking,

    -- rolling baselines
    COALESCE(r30.rest_avg_minutes_30d,   0) AS rest_avg_minutes_30d,
    COALESCE(r30.rest_fail_rate_30d,     0) AS rest_fail_rate_30d,
    COALESCE(c30.courier_avg_minutes_30d,0) AS courier_avg_minutes_30d,
    COALESCE(c30.courier_fail_rate_30d,  0) AS courier_fail_rate_30d
FROM base b
LEFT JOIN rest_30    r30 ON r30.restaurant_id = b.restaurant_id
LEFT JOIN courier_30 c30 ON c30.courier_id    = b.courier_id;


-- --- DATASET3  DELIVERY OPTIMIZATION ---
CREATE OR REPLACE VIEW ML_Restaurant_KPI_Dataset AS
WITH order_stats AS (
  SELECT
      o.restaurant_id,
      COUNT(*)                                 AS orders_count,
      COALESCE(SUM(o.total),0)                 AS revenue,
      COUNT(DISTINCT o.customer_id)            AS unique_customers
  FROM orders o
  GROUP BY o.restaurant_id
),
order_customer_counts AS (
  SELECT
      o.restaurant_id,
      o.customer_id,
      COUNT(*) AS cust_orders_at_rest
  FROM orders o
  GROUP BY o.restaurant_id, o.customer_id
),
reorders AS (
  SELECT
      restaurant_id,
      SUM(cust_orders_at_rest >= 2)                              AS repeat_customers,
      COUNT(*)                                                   AS unique_customers_dup,
      SUM(cust_orders_at_rest >= 2) / NULLIF(COUNT(*),0)         AS reorder_rate
  FROM order_customer_counts
  GROUP BY restaurant_id
),
review_stats AS (
  SELECT
      rv.restaurant_id,
      AVG(rv.rating)            AS avg_rating,
      COUNT(*)                  AS review_count
  FROM reviews rv
  GROUP BY rv.restaurant_id
),
delivery_stats AS (
  SELECT
      o.restaurant_id,
      AVG(TIMESTAMPDIFF(MINUTE, d.pickup_time, d.dropoff_time))  AS avg_delivery_minutes,
      AVG(CASE WHEN d.status = 'failed' THEN 1 ELSE 0 END)       AS fail_rate
  FROM deliveries d
  JOIN orders o ON o.order_id = d.order_id
  GROUP BY o.restaurant_id
),
menu_stats AS (
  SELECT
      r.restaurant_id,
      COUNT(DISTINCT mi.item_id) AS menu_items_count
  FROM restaurants r
  LEFT JOIN menus m      ON m.restaurant_id = r.restaurant_id
  LEFT JOIN menu_items mi ON mi.menu_id = m.menu_id
  GROUP BY r.restaurant_id
),
recent_30 AS (
  SELECT
      o.restaurant_id,
      COUNT(*)                 AS orders_30,
      COALESCE(SUM(o.total),0) AS revenue_30
  FROM orders o
  WHERE o.order_time >= (CURDATE() - INTERVAL 30 DAY)
  GROUP BY o.restaurant_id
)
SELECT
    r.restaurant_id,
    r.name AS restaurant_name,

    -- Commercial
    COALESCE(os.orders_count,0)                      AS orders_count,
    COALESCE(os.revenue,0)                           AS revenue,
    (COALESCE(os.revenue,0) / NULLIF(os.orders_count,0)) AS avg_order_value,
    COALESCE(os.unique_customers,0)                  AS unique_customers,

    -- Loyalty
    COALESCE(ro.repeat_customers,0)                  AS repeat_customers,
    COALESCE(ro.reorder_rate,0)                      AS reorder_rate,

    -- Quality
    COALESCE(rs.avg_rating,0)                        AS avg_rating,
    COALESCE(rs.review_count,0)                      AS review_count,

    -- Operations
    COALESCE(ds.avg_delivery_minutes,0)              AS avg_delivery_minutes,
    COALESCE(ds.fail_rate,0)                         AS fail_rate,

    -- Menu
    COALESCE(ms.menu_items_count,0)                  AS menu_items_count,

    -- Recent growth
    COALESCE(r30.orders_30,0)                        AS orders_30,
    COALESCE(r30.revenue_30,0)                       AS revenue_30
FROM restaurants r
LEFT JOIN order_stats   os  ON os.restaurant_id  = r.restaurant_id
LEFT JOIN reorders      ro  ON ro.restaurant_id  = r.restaurant_id
LEFT JOIN review_stats  rs  ON rs.restaurant_id  = r.restaurant_id
LEFT JOIN delivery_stats ds ON ds.restaurant_id  = r.restaurant_id
LEFT JOIN menu_stats    ms  ON ms.restaurant_id  = r.restaurant_id
LEFT JOIN recent_30     r30 ON r30.restaurant_id = r.restaurant_id;


-- ---------------- Examples: JSON & XML updates ----------------

-- Update a customer's JSON preference
-- UPDATE customers SET preferences_json = JSON_SET(preferences_json, '$.spicy', true) WHERE customer_id = 1001;

-- Update a shipping label XML stored in TEXT via string replacement:
-- UPDATE deliveries
-- SET shipping_label_xml = REPLACE(shipping_label_xml, '</carrier>', '</carrier><note>Leave at door</note>')
-- WHERE order_id = 6001;
SHOW VARIABLES LIKE 'local_infile';

SHOW VARIABLES LIKE 'secure_file_priv';


USE FoodExpressDB;

SHOW VARIABLES LIKE 'secure_file_priv';   -- should equal: C:\ProgramData\MySQL\MySQL Server 8.0\Uploads\
GRANT FILE ON *.* TO 'root'@'localhost';
FLUSH PRIVILEGES;

SELECT @@secure_file_priv;

USE FoodExpressDB;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.4/Uploads/users.csv'
INTO TABLE users
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(user_id,full_name,email,phone,role,created_at);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.4/Uploads/customers.csv'
INTO TABLE customers
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(customer_id,loyalty_status,preferences_json);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.4/Uploads/addresses.csv'
INTO TABLE addresses
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(address_id,customer_id,address_line,city,province,postal_code,country,latitude,longitude,is_default);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.4/Uploads/restaurants.csv'
INTO TABLE restaurants
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(restaurant_id,owner_user_id,name,cuisine_type,phone,city,rating_avg,hours_json);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.4/Uploads/menus.csv'
INTO TABLE menus
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(menu_id,restaurant_id,title,is_active,created_at);


-- 6) menu_items (child of menus)
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.4/Uploads/menu_items.csv'
INTO TABLE menu_items
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(item_id,menu_id,name,description,price,calories,is_veg,allergens_json);

-- 7) couriers (child of users via user_id)
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.4/Uploads/couriers.csv'
INTO TABLE couriers
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(courier_id,user_id,vehicle_type,license_no,hired_at,is_active);

-- 8) orders (child of customers, restaurants, addresses)
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.4/Uploads/orders.csv'
INTO TABLE orders
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id,customer_id,restaurant_id,address_id,order_time,status,subtotal,tax,delivery_fee,total,special_instructions);

USE FoodExpressDB;
DELIMITER //

-- Drop old triggers if they exist
DROP TRIGGER IF EXISTS trg_order_items_after_ins; //
DROP TRIGGER IF EXISTS trg_order_items_after_del; //
DROP TRIGGER IF EXISTS trg_reviews_after_ins; //

-- Recreate: recompute order totals after INSERT on order_items
CREATE TRIGGER trg_order_items_after_ins
AFTER INSERT ON order_items
FOR EACH ROW
BEGIN
  DECLARE v_subtotal DECIMAL(10,2);
  SELECT COALESCE(SUM(line_total),0)
    INTO v_subtotal
    FROM order_items
   WHERE order_id = NEW.order_id;

  UPDATE orders
     SET subtotal = v_subtotal,
         tax      = ROUND(v_subtotal * 0.13, 2),
         total    = ROUND(v_subtotal * 1.13 + delivery_fee, 2)
   WHERE order_id = NEW.order_id;
END;
//

-- Recreate: recompute order totals after DELETE on order_items
CREATE TRIGGER trg_order_items_after_del
AFTER DELETE ON order_items
FOR EACH ROW
BEGIN
  DECLARE v_subtotal DECIMAL(10,2);
  SELECT COALESCE(SUM(line_total),0)
    INTO v_subtotal
    FROM order_items
   WHERE order_id = OLD.order_id;

  UPDATE orders
     SET subtotal = v_subtotal,
         tax      = ROUND(v_subtotal * 0.13, 2),
         total    = ROUND(v_subtotal * 1.13 + delivery_fee, 2)
   WHERE order_id = OLD.order_id;
END;
//

-- Recreate: refresh restaurant avg rating after a new review
CREATE TRIGGER trg_reviews_after_ins
AFTER INSERT ON reviews
FOR EACH ROW
BEGIN
  DECLARE v_avg DECIMAL(10,2);
  SELECT ROUND(AVG(rating), 2)
    INTO v_avg
    FROM reviews
   WHERE restaurant_id = NEW.restaurant_id;

  UPDATE restaurants
     SET rating_avg = v_avg
   WHERE restaurant_id = NEW.restaurant_id;
END;
//
DELIMITER ;

-- you were on this step:
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.4/Uploads/order_items.csv'
INTO TABLE order_items
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id,item_id,quantity,unit_price,line_total);

-- 10) payments (child of orders)
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.4/Uploads/payments.csv'
INTO TABLE payments
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(payment_id,order_id,method,amount,status,transaction_json);

-- 11) deliveries (child of orders & couriers)
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.4/Uploads/deliveries.csv'
INTO TABLE deliveries
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(delivery_id,order_id,courier_id,pickup_time,dropoff_time,status,distance_km,shipping_label_xml);

-- 12) reviews (child of orders, customers, restaurants)
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.4/Uploads/reviews.csv'
INTO TABLE reviews
FIELDS TERMINATED BY ',' ENCLOSED BY '"' ESCAPED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(review_id,order_id,customer_id,restaurant_id,rating,comments,created_at,sentiment_json);

-- Quick verification
SELECT COUNT(*) AS users_cnt      FROM users;
SELECT COUNT(*) AS customers_cnt  FROM customers;
SELECT COUNT(*) AS addresses_cnt  FROM addresses;
SELECT COUNT(*) AS restaurants_cnt FROM restaurants;
SELECT COUNT(*) AS menus_cnt      FROM menus;
SELECT COUNT(*) AS items_cnt      FROM menu_items;
SELECT COUNT(*) AS couriers_cnt   FROM couriers;
SELECT COUNT(*) AS orders_cnt     FROM orders;
SELECT COUNT(*) AS oi_cnt         FROM order_items;
SELECT COUNT(*) AS payments_cnt   FROM payments;
SELECT COUNT(*) AS deliveries_cnt FROM deliveries;
SELECT COUNT(*) AS reviews_cnt    FROM reviews;

SELECT 'users'       AS table_name, COUNT(*) AS row_count FROM users
UNION ALL SELECT 'customers',   COUNT(*) FROM customers
UNION ALL SELECT 'addresses',   COUNT(*) FROM addresses
UNION ALL SELECT 'restaurants', COUNT(*) FROM restaurants
UNION ALL SELECT 'menus',       COUNT(*) FROM menus
UNION ALL SELECT 'menu_items',  COUNT(*) FROM menu_items
UNION ALL SELECT 'couriers',    COUNT(*) FROM couriers
UNION ALL SELECT 'orders',      COUNT(*) FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'payments',    COUNT(*) FROM payments
UNION ALL SELECT 'deliveries',  COUNT(*) FROM deliveries
UNION ALL SELECT 'reviews',     COUNT(*) FROM reviews;


SELECT COUNT(*) orders_cnt     FROM orders;
SELECT COUNT(*) order_items_cnt FROM order_items;
SELECT subtotal, tax, delivery_fee, total
FROM orders
ORDER BY order_id DESC
LIMIT 5;

USE FoodExpressDB;

-- sampleQuery
SELECT
  delivery_id,
  order_id,
  REGEXP_REPLACE(
    REGEXP_SUBSTR(shipping_label_xml, '<trackingNumber>[^<]+</trackingNumber>', 1, 1, 'c'),
    '^<trackingNumber>|</trackingNumber>$',
    ''
  ) AS tracking_number
FROM deliveries
LIMIT 20;
-- QUERY1: -- Customer activity ranking with JSON extraction & window functions--
WITH cust_item AS (
  SELECT 
      c.customer_id,
      u.full_name,
      JSON_UNQUOTE(JSON_EXTRACT(c.preferences_json,'$.spicy')) AS likes_spicy,  -- true/false if present
      JSON_UNQUOTE(JSON_EXTRACT(mi.allergens_json,'$.spice_level')) AS spice_level,
      COUNT(*) AS times_ordered
  FROM customers c
  JOIN users u        ON u.user_id = c.customer_id
  JOIN orders o       ON o.customer_id = c.customer_id
  JOIN order_items oi ON oi.order_id = o.order_id
  JOIN menu_items mi  ON mi.item_id = oi.item_id
  GROUP BY c.customer_id, u.full_name, likes_spicy, spice_level
),
ranked AS (
  SELECT 
      *,
      RANK() OVER (PARTITION BY customer_id ORDER BY times_ordered DESC) AS spice_rank
  FROM cust_item
)
SELECT 
    customer_id,
    full_name,
    likes_spicy,
    spice_level AS top_spice_level,
    times_ordered
FROM ranked
WHERE spice_rank = 1
ORDER BY times_ordered DESC
LIMIT 20;

-- QUERY2 -- Delivery performance with XML parsing & failure correlation -- 

WITH delivered AS (
  SELECT
      d.delivery_id,
      d.courier_id,
      TIMESTAMPDIFF(MINUTE, d.pickup_time, d.dropoff_time) AS minutes_to_deliver,
      -- Extract trackingNumber using regex (cleaner than nested SUBSTRING_INDEX)
      REGEXP_SUBSTR(d.shipping_label_xml, '<trackingNumber>[^<]+</trackingNumber>') AS tracking_tag
  FROM deliveries d
  WHERE d.status = 'delivered'
),
by_courier AS (
  SELECT
      c.courier_id,
      u.full_name AS courier_name,
      COUNT(*) AS deliveries,
      AVG(minutes_to_deliver) AS avg_minutes,
      SUM(CASE WHEN tracking_tag IS NOT NULL THEN 1 ELSE 0 END) AS with_tracking
  FROM delivered d
  JOIN couriers c ON c.courier_id = d.courier_id
  JOIN users u    ON u.user_id = c.user_id
  GROUP BY c.courier_id, u.full_name
),
fail_corr AS (
  SELECT
      d.courier_id,
      AVG(CASE WHEN d.status = 'failed' THEN 1 ELSE 0 END)                        AS fail_rate,
      AVG(CASE 
            WHEN REGEXP_SUBSTR(d.shipping_label_xml,'<trackingNumber>[^<]+</trackingNumber>') IS NULL 
            THEN (d.status = 'failed') ELSE 0 END
          ) AS fail_rate_when_no_tracking
  FROM deliveries d
  GROUP BY d.courier_id
)
SELECT 
    b.courier_id,
    b.courier_name,
    b.deliveries,
    ROUND(b.avg_minutes, 1) AS avg_minutes,
    b.with_tracking,
    ROUND(f.fail_rate * 100, 2) AS fail_rate_pct,
    ROUND(f.fail_rate_when_no_tracking * 100, 2) AS fail_rate_no_tracking_pct
FROM by_courier b
JOIN fail_corr f ON f.courier_id = b.courier_id
WHERE b.deliveries >= 5
ORDER BY avg_minutes ASC, fail_rate_no_tracking_pct ASC;

-- QUERY3: -- Regional customer spend with payment (JSON) & delivery (XML) signals

WITH primary_city AS (
  -- Pick the latest default address per customer as their "primary" city
  SELECT a.customer_id,
         a.city,
         ROW_NUMBER() OVER (PARTITION BY a.customer_id ORDER BY a.is_default DESC, a.address_id DESC) AS rn
  FROM addresses a
),
cust_spend AS (
  SELECT 
      o.customer_id,
      SUM(o.total) AS total_spent,
      COUNT(*)     AS orders_count
  FROM orders o
  GROUP BY o.customer_id
),
pay_methods AS (
  SELECT 
      p.order_id,
      JSON_UNQUOTE(JSON_EXTRACT(p.transaction_json, '$.method')) AS pay_method
  FROM payments p
),
delivery_flags AS (
  SELECT 
      d.order_id,
      CASE 
        WHEN REGEXP_SUBSTR(d.shipping_label_xml,'<trackingNumber>[^<]+</trackingNumber>') IS NULL 
        THEN 0 ELSE 1 
      END AS has_tracking
  FROM deliveries d
),
city_rollup AS (
  SELECT 
      u.user_id        AS customer_id,
      u.full_name,
      pc.city,
      cs.total_spent,
      cs.orders_count,
      -- Most-used payment method for this customer
      (
        SELECT pm.pay_method
        FROM pay_methods pm
        JOIN orders o2 ON o2.order_id = pm.order_id
        WHERE o2.customer_id = u.user_id
        GROUP BY pm.pay_method
        ORDER BY COUNT(*) DESC
        LIMIT 1
      ) AS top_payment_method,
      -- Share of customer’s delivered orders that had a tracking number
      (
        SELECT ROUND(AVG(df.has_tracking) * 100, 2)
        FROM delivery_flags df
        JOIN orders o3 ON o3.order_id = df.order_id
        WHERE o3.customer_id = u.user_id
      ) AS tracking_share_pct
  FROM users u
  JOIN customers c   ON c.customer_id = u.user_id
  LEFT JOIN (SELECT * FROM primary_city WHERE rn = 1) pc ON pc.customer_id = u.user_id
  LEFT JOIN cust_spend cs ON cs.customer_id = u.user_id
)
SELECT
    customer_id,
    full_name,
    city,
    COALESCE(total_spent, 0) AS total_spent,
    COALESCE(orders_count, 0) AS orders_count,
    top_payment_method,
    tracking_share_pct,
    DENSE_RANK() OVER (PARTITION BY city ORDER BY COALESCE(total_spent,0) DESC) AS city_spend_rank
FROM city_rollup
WHERE city IS NOT NULL
ORDER BY city, city_spend_rank
LIMIT 100;

-- QUERY4: -- Restaurant performance scorecard (orders + reviews + delivery KPIs) -- 

WITH order_stats AS (
  SELECT 
      o.restaurant_id,
      COUNT(*)                  AS orders_count,
      COALESCE(SUM(o.total),0)  AS revenue
  FROM orders o
  GROUP BY o.restaurant_id
),
review_stats AS (
  SELECT 
      rv.restaurant_id,
      ROUND(AVG(rv.rating), 2)  AS avg_rating,
      COUNT(*)                  AS review_count
  FROM reviews rv
  GROUP BY rv.restaurant_id
),
delivery_stats AS (
  SELECT 
      o.restaurant_id,
      AVG(TIMESTAMPDIFF(MINUTE, d.pickup_time, d.dropoff_time)) AS avg_delivery_minutes,
      AVG(CASE WHEN d.status = 'failed' THEN 1 ELSE 0 END)      AS fail_rate
  FROM deliveries d
  JOIN orders o ON o.order_id = d.order_id
  GROUP BY o.restaurant_id
),
combined AS (
  SELECT 
      r.restaurant_id,
      r.name AS restaurant_name,
      os.orders_count,
      os.revenue,
      rs.avg_rating,
      rs.review_count,
      ds.avg_delivery_minutes,
      ds.fail_rate
  FROM restaurants r
  LEFT JOIN order_stats    os ON os.restaurant_id = r.restaurant_id
  LEFT JOIN review_stats   rs ON rs.restaurant_id = r.restaurant_id
  LEFT JOIN delivery_stats ds ON ds.restaurant_id = r.restaurant_id
)
SELECT
    restaurant_id,
    restaurant_name,
    COALESCE(orders_count, 0)                         AS orders_count,
    COALESCE(revenue, 0)                              AS revenue,
    avg_rating,
    review_count,
    ROUND(avg_delivery_minutes, 1)                    AS avg_delivery_minutes,
    ROUND(fail_rate * 100, 2)                         AS fail_rate_pct,
    RANK() OVER (ORDER BY COALESCE(revenue,0) DESC)   AS revenue_rank,
    RANK() OVER (ORDER BY COALESCE(avg_rating,0) DESC)AS rating_rank
FROM combined
WHERE COALESCE(orders_count,0) > 0
ORDER BY revenue DESC, avg_rating DESC
LIMIT 20;














