-- =====================================================================
-- 02_modelo_dimensional.sql
-- Crea el esquema "dw" (data warehouse) con el ESQUEMA ESTRELLA:
--   1 tabla de hechos  : dw.fact_ventas_item
--   6 dimensiones      : fecha (2 roles), cliente, producto, vendedor,
--                        estado_pedido, pago
-- GRANULARIDAD: una fila de la tabla de hechos = un ítem (producto) vendido
-- dentro de un pedido, identificado por (order_id, order_item_id).
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS dw;

DROP TABLE IF EXISTS dw.fact_ventas_item, dw.dim_fecha, dw.dim_cliente, dw.dim_producto,
                     dw.dim_vendedor, dw.dim_estado_pedido, dw.dim_pago CASCADE;

-- ---------------------------- DIMENSIONES ----------------------------
CREATE TABLE dw.dim_fecha (
    fecha_key         INTEGER PRIMARY KEY,          -- formato AAAAMMDD (ej. 20180315)
    fecha             DATE NOT NULL UNIQUE,
    anio              SMALLINT NOT NULL,
    trimestre         SMALLINT NOT NULL,
    mes               SMALLINT NOT NULL,
    nombre_mes        VARCHAR(12) NOT NULL,
    anio_mes          CHAR(7) NOT NULL,             -- 'AAAA-MM' (para ordenar y graficar)
    dia               SMALLINT NOT NULL,
    dia_semana_num    SMALLINT NOT NULL,            -- 1 = lunes ... 7 = domingo
    nombre_dia        VARCHAR(12) NOT NULL,
    es_fin_de_semana  BOOLEAN NOT NULL
);

CREATE TABLE dw.dim_cliente (
    cliente_key         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_unique_id  VARCHAR(32) NOT NULL UNIQUE,   -- clave de negocio (persona real)
    ciudad              VARCHAR(100),
    estado              CHAR(2),
    region              VARCHAR(20),
    zip_prefix          VARCHAR(5),
    lat                 NUMERIC(10,6),
    lng                 NUMERIC(10,6)
);

CREATE TABLE dw.dim_vendedor (
    vendedor_key  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seller_id     VARCHAR(32) NOT NULL UNIQUE,
    ciudad        VARCHAR(100),
    estado        CHAR(2)
);

CREATE TABLE dw.dim_producto (
    producto_key  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id    VARCHAR(32) NOT NULL UNIQUE,
    categoria_pt  VARCHAR(100) NOT NULL,
    categoria_en  VARCHAR(100) NOT NULL,
    peso_g        NUMERIC(10,2),
    largo_cm      NUMERIC(8,2),
    alto_cm       NUMERIC(8,2),
    ancho_cm      NUMERIC(8,2)
);

CREATE TABLE dw.dim_estado_pedido (
    estado_key        SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_status      VARCHAR(20) NOT NULL UNIQUE,
    estado_es         VARCHAR(30) NOT NULL,
    es_ingreso_valido BOOLEAN NOT NULL            -- FALSE = cancelado / no disponible
);

CREATE TABLE dw.dim_pago (                         -- dimensión "basura" (junk): combinación tipo + cuotas
    pago_key        SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo_pago       VARCHAR(20) NOT NULL,
    grupo_cuotas    VARCHAR(20) NOT NULL,
    orden_cuotas    SMALLINT NOT NULL,
    UNIQUE (tipo_pago, grupo_cuotas)
);

-- ------------------------- TABLA DE HECHOS ---------------------------
CREATE TABLE dw.fact_ventas_item (
    -- Clave primaria compuesta: order_id es una DIMENSIÓN DEGENERADA
    order_id           VARCHAR(32) NOT NULL,
    order_item_id      SMALLINT    NOT NULL,
    -- Claves foráneas (una por dimensión)
    fecha_compra_key   INTEGER  NOT NULL REFERENCES dw.dim_fecha(fecha_key),
    fecha_entrega_key  INTEGER           REFERENCES dw.dim_fecha(fecha_key),  -- NULL = aún no entregado
    cliente_key        INTEGER  NOT NULL REFERENCES dw.dim_cliente(cliente_key),
    producto_key       INTEGER  NOT NULL REFERENCES dw.dim_producto(producto_key),
    vendedor_key       INTEGER  NOT NULL REFERENCES dw.dim_vendedor(vendedor_key),
    estado_key         SMALLINT NOT NULL REFERENCES dw.dim_estado_pedido(estado_key),
    pago_key           SMALLINT NOT NULL REFERENCES dw.dim_pago(pago_key),
    -- Medidas aditivas
    price              NUMERIC(10,2) NOT NULL,     -- ingreso del ítem
    freight_value      NUMERIC(10,2) NOT NULL,     -- flete del ítem
    cantidad           SMALLINT NOT NULL DEFAULT 1,
    -- Medidas derivadas (se promedian, NO se suman); valen para todos los ítems del pedido
    dias_entrega       NUMERIC(8,2),               -- fecha entrega - fecha compra (NULL si no entregado)
    dias_retraso       SMALLINT,                   -- días de atraso vs. fecha estimada (0 = a tiempo)
    entrega_a_tiempo   SMALLINT CHECK (entrega_a_tiempo IN (0,1)),
    review_score       SMALLINT CHECK (review_score BETWEEN 1 AND 5),
    PRIMARY KEY (order_id, order_item_id)
);

CREATE INDEX ix_fact_fecha_compra ON dw.fact_ventas_item (fecha_compra_key);
CREATE INDEX ix_fact_cliente      ON dw.fact_ventas_item (cliente_key);
CREATE INDEX ix_fact_producto     ON dw.fact_ventas_item (producto_key);
CREATE INDEX ix_fact_vendedor     ON dw.fact_ventas_item (vendedor_key);
CREATE INDEX ix_fact_estado       ON dw.fact_ventas_item (estado_key);

COMMENT ON TABLE dw.fact_ventas_item IS
 'GRANULARIDAD: una fila = un ítem (producto) vendido dentro de un pedido (order_id + order_item_id).';
COMMENT ON COLUMN dw.fact_ventas_item.review_score IS
 'Nivel de pedido repetido en cada ítem: NO sumar; contar pedidos distintos antes de promediar.';
