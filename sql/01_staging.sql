-- =====================================================================
-- 01_staging.sql
-- Crea el esquema "stg" (staging = zona de aterrizaje de datos YA LIMPIOS).
-- Python (etl_olist.py) llena estas tablas. Se puede ejecutar varias veces.
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS stg;

DROP TABLE IF EXISTS stg.pedidos, stg.items, stg.clientes, stg.vendedores,
                     stg.productos, stg.pagos_pedido, stg.resenas, stg.geolocalizacion CASCADE;

CREATE TABLE stg.pedidos (
    order_id                 VARCHAR(32) PRIMARY KEY,
    customer_id              VARCHAR(32) NOT NULL,
    order_status             VARCHAR(20) NOT NULL,
    purchase_ts              TIMESTAMP   NOT NULL,
    approved_ts              TIMESTAMP,
    delivered_carrier_ts     TIMESTAMP,
    delivered_customer_ts    TIMESTAMP,
    estimated_delivery_ts    TIMESTAMP
);

CREATE TABLE stg.items (
    order_id            VARCHAR(32) NOT NULL,
    order_item_id       SMALLINT    NOT NULL,
    product_id          VARCHAR(32) NOT NULL,
    seller_id           VARCHAR(32) NOT NULL,
    shipping_limit_ts   TIMESTAMP,
    price               NUMERIC(10,2) NOT NULL,
    freight_value       NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE stg.clientes (
    customer_id         VARCHAR(32) PRIMARY KEY,
    customer_unique_id  VARCHAR(32) NOT NULL,
    zip_prefix          VARCHAR(5),
    ciudad              VARCHAR(100),
    estado              CHAR(2)
);

CREATE TABLE stg.vendedores (
    seller_id    VARCHAR(32) PRIMARY KEY,
    zip_prefix   VARCHAR(5),
    ciudad       VARCHAR(100),
    estado       CHAR(2)
);

CREATE TABLE stg.productos (
    product_id     VARCHAR(32) PRIMARY KEY,
    categoria_pt   VARCHAR(100) NOT NULL,
    categoria_en   VARCHAR(100) NOT NULL,
    peso_g         NUMERIC(10,2),
    largo_cm       NUMERIC(8,2),
    alto_cm        NUMERIC(8,2),
    ancho_cm       NUMERIC(8,2)
);

CREATE TABLE stg.pagos_pedido (          -- una fila por pedido (pagos resumidos)
    order_id              VARCHAR(32) PRIMARY KEY,
    tipo_pago_principal   VARCHAR(20) NOT NULL,
    cuotas_max            SMALLINT,
    valor_total_pago      NUMERIC(12,2),
    n_pagos               SMALLINT
);

CREATE TABLE stg.resenas (               -- una fila por pedido (la reseña más reciente)
    order_id       VARCHAR(32) PRIMARY KEY,
    review_score   SMALLINT NOT NULL
);

CREATE TABLE stg.geolocalizacion (       -- una fila por prefijo de código postal
    zip_prefix  VARCHAR(5) PRIMARY KEY,
    lat         NUMERIC(10,6),
    lng         NUMERIC(10,6)
);
