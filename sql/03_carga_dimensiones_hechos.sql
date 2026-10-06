-- =====================================================================
-- 03_carga_dimensiones_hechos.sql
-- Llena las dimensiones y luego la tabla de hechos desde el esquema stg.
-- ORDEN OBLIGATORIO: primero dimensiones, después hechos (por las claves foráneas).
-- Se puede re-ejecutar: vacía las tablas antes de cargar.
-- =====================================================================
TRUNCATE dw.fact_ventas_item, dw.dim_fecha, dw.dim_cliente, dw.dim_producto,
         dw.dim_vendedor, dw.dim_estado_pedido, dw.dim_pago RESTART IDENTITY CASCADE;

-- 1) dim_fecha: un registro por día entre 2016 y 2019 (se genera, no viene del CSV)
INSERT INTO dw.dim_fecha (fecha_key, fecha, anio, trimestre, mes, nombre_mes, anio_mes,
                          dia, dia_semana_num, nombre_dia, es_fin_de_semana)
SELECT to_char(d, 'YYYYMMDD')::int,
       d::date,
       EXTRACT(YEAR    FROM d)::smallint,
       EXTRACT(QUARTER FROM d)::smallint,
       EXTRACT(MONTH   FROM d)::smallint,
       (ARRAY['Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio','Agosto',
              'Septiembre','Octubre','Noviembre','Diciembre'])[EXTRACT(MONTH FROM d)::int],
       to_char(d, 'YYYY-MM'),
       EXTRACT(DAY FROM d)::smallint,
       EXTRACT(ISODOW FROM d)::smallint,
       (ARRAY['Lunes','Martes','Miércoles','Jueves','Viernes','Sábado','Domingo'])[EXTRACT(ISODOW FROM d)::int],
       EXTRACT(ISODOW FROM d) IN (6,7)
FROM generate_series('2016-01-01'::timestamp, '2019-12-31'::timestamp, interval '1 day') AS d;

-- 2) dim_cliente: UNA fila por persona real (customer_unique_id).
--    Si una persona compró desde ciudades distintas, se conserva la ubicación de su compra más reciente.
INSERT INTO dw.dim_cliente (customer_unique_id, ciudad, estado, region, zip_prefix, lat, lng)
SELECT DISTINCT ON (c.customer_unique_id)
       c.customer_unique_id, c.ciudad, c.estado,
       CASE
         WHEN c.estado IN ('AC','AP','AM','PA','RO','RR','TO')                          THEN 'Norte'
         WHEN c.estado IN ('AL','BA','CE','MA','PB','PE','PI','RN','SE')                THEN 'Nordeste'
         WHEN c.estado IN ('DF','GO','MT','MS')                                         THEN 'Centro-Oeste'
         WHEN c.estado IN ('ES','MG','RJ','SP')                                         THEN 'Sudeste'
         WHEN c.estado IN ('PR','RS','SC')                                              THEN 'Sur'
         ELSE 'Sin región'
       END,
       c.zip_prefix, g.lat, g.lng
FROM stg.clientes c
JOIN stg.pedidos o           ON o.customer_id = c.customer_id
LEFT JOIN stg.geolocalizacion g ON g.zip_prefix = c.zip_prefix
ORDER BY c.customer_unique_id, o.purchase_ts DESC;

-- 3) dim_vendedor
INSERT INTO dw.dim_vendedor (seller_id, ciudad, estado)
SELECT seller_id, ciudad, estado FROM stg.vendedores;

-- 4) dim_producto
INSERT INTO dw.dim_producto (product_id, categoria_pt, categoria_en, peso_g, largo_cm, alto_cm, ancho_cm)
SELECT product_id, categoria_pt, categoria_en, peso_g, largo_cm, alto_cm, ancho_cm
FROM stg.productos;

-- 5) dim_estado_pedido (lista fija de los 8 estados del dataset)
INSERT INTO dw.dim_estado_pedido (order_status, estado_es, es_ingreso_valido) VALUES
 ('delivered',   'Entregado',     TRUE),
 ('shipped',     'Enviado',       TRUE),
 ('invoiced',    'Facturado',     TRUE),
 ('processing',  'En proceso',    TRUE),
 ('approved',    'Aprobado',      TRUE),
 ('created',     'Creado',        TRUE),
 ('canceled',    'Cancelado',     FALSE),
 ('unavailable', 'No disponible', FALSE);

-- 6) dim_pago: todas las combinaciones tipo de pago x grupo de cuotas
INSERT INTO dw.dim_pago (tipo_pago, grupo_cuotas, orden_cuotas)
SELECT t.tipo, g.grupo, g.orden
FROM (VALUES ('credit_card'),('boleto'),('voucher'),('debit_card'),('not_defined')) AS t(tipo)
CROSS JOIN (VALUES ('1 pago',1),('2-3 cuotas',2),('4-6 cuotas',3),
                   ('7-12 cuotas',4),('Más de 12 cuotas',5)) AS g(grupo, orden);

-- 7) fact_ventas_item: una fila por ítem vendido
INSERT INTO dw.fact_ventas_item
      (order_id, order_item_id, fecha_compra_key, fecha_entrega_key, cliente_key, producto_key,
       vendedor_key, estado_key, pago_key, price, freight_value, cantidad,
       dias_entrega, dias_retraso, entrega_a_tiempo, review_score)
SELECT i.order_id,
       i.order_item_id,
       to_char(o.purchase_ts, 'YYYYMMDD')::int,
       CASE WHEN o.delivered_customer_ts IS NOT NULL
            THEN to_char(o.delivered_customer_ts, 'YYYYMMDD')::int END,
       dc.cliente_key,
       dp.producto_key,
       dv.vendedor_key,
       de.estado_key,
       dpg.pago_key,
       i.price,
       i.freight_value,
       1,
       CASE WHEN o.delivered_customer_ts IS NOT NULL
            THEN ROUND((EXTRACT(EPOCH FROM (o.delivered_customer_ts - o.purchase_ts)) / 86400.0)::numeric, 2) END,
       CASE WHEN o.delivered_customer_ts IS NOT NULL
            THEN GREATEST(0, o.delivered_customer_ts::date - o.estimated_delivery_ts::date) END,
       CASE WHEN o.delivered_customer_ts IS NOT NULL
            THEN (o.delivered_customer_ts::date <= o.estimated_delivery_ts::date)::int END,
       r.review_score
FROM stg.items i
JOIN stg.pedidos o            ON o.order_id = i.order_id
JOIN stg.clientes c           ON c.customer_id = o.customer_id
JOIN dw.dim_cliente dc        ON dc.customer_unique_id = c.customer_unique_id
JOIN dw.dim_producto dp       ON dp.product_id = i.product_id
JOIN dw.dim_vendedor dv       ON dv.seller_id = i.seller_id
JOIN dw.dim_estado_pedido de  ON de.order_status = o.order_status
LEFT JOIN stg.pagos_pedido pg ON pg.order_id = i.order_id
JOIN dw.dim_pago dpg          ON dpg.tipo_pago = COALESCE(pg.tipo_pago_principal, 'not_defined')
                             AND dpg.grupo_cuotas = CASE
                                    WHEN COALESCE(pg.cuotas_max, 1) <= 1  THEN '1 pago'
                                    WHEN pg.cuotas_max <= 3               THEN '2-3 cuotas'
                                    WHEN pg.cuotas_max <= 6               THEN '4-6 cuotas'
                                    WHEN pg.cuotas_max <= 12              THEN '7-12 cuotas'
                                    ELSE 'Más de 12 cuotas' END
LEFT JOIN stg.resenas r       ON r.order_id = i.order_id;

ANALYZE dw.dim_fecha; ANALYZE dw.dim_cliente; ANALYZE dw.dim_producto; ANALYZE dw.dim_vendedor; ANALYZE dw.dim_estado_pedido; ANALYZE dw.dim_pago; ANALYZE dw.fact_ventas_item;   -- actualiza estadísticas para que las consultas sean rápidas
