-- =====================================================================
-- 04_validaciones.sql
-- Consultas de VALIDACIÓN. Resultado esperado indicado en cada bloque.
-- Ejecutar completo y tomar capturas de pantalla como evidencia.
-- =====================================================================

-- ---------- 1. CANTIDAD DE REGISTROS CARGADOS ----------
SELECT 'dim_fecha' AS tabla, COUNT(*) AS filas FROM dw.dim_fecha
UNION ALL SELECT 'dim_cliente',       COUNT(*) FROM dw.dim_cliente
UNION ALL SELECT 'dim_vendedor',      COUNT(*) FROM dw.dim_vendedor
UNION ALL SELECT 'dim_producto',      COUNT(*) FROM dw.dim_producto
UNION ALL SELECT 'dim_estado_pedido', COUNT(*) FROM dw.dim_estado_pedido
UNION ALL SELECT 'dim_pago',          COUNT(*) FROM dw.dim_pago
UNION ALL SELECT 'fact_ventas_item',  COUNT(*) FROM dw.fact_ventas_item
ORDER BY 1;

-- Conciliación staging vs hechos. ESPERADO: diferencia = 0
SELECT (SELECT COUNT(*) FROM stg.items i JOIN stg.pedidos o USING (order_id)) AS items_en_staging,
       (SELECT COUNT(*) FROM dw.fact_ventas_item)                             AS filas_en_hechos,
       (SELECT COUNT(*) FROM stg.items) - (SELECT COUNT(*) FROM dw.fact_ventas_item) AS diferencia;

-- ---------- 2. INTEGRIDAD DE LAS RELACIONES ----------
-- Hechos sin dimensión correspondiente. ESPERADO: todo en 0
SELECT
  COUNT(*) FILTER (WHERE fc.fecha_key  IS NULL)                                   AS sin_fecha_compra,
  COUNT(*) FILTER (WHERE f.fecha_entrega_key IS NOT NULL AND fe.fecha_key IS NULL) AS sin_fecha_entrega,
  COUNT(*) FILTER (WHERE c.cliente_key  IS NULL)                                  AS sin_cliente,
  COUNT(*) FILTER (WHERE p.producto_key IS NULL)                                  AS sin_producto,
  COUNT(*) FILTER (WHERE v.vendedor_key IS NULL)                                  AS sin_vendedor,
  COUNT(*) FILTER (WHERE e.estado_key   IS NULL)                                  AS sin_estado,
  COUNT(*) FILTER (WHERE g.pago_key     IS NULL)                                  AS sin_pago
FROM dw.fact_ventas_item f
LEFT JOIN dw.dim_fecha fc         ON fc.fecha_key = f.fecha_compra_key
LEFT JOIN dw.dim_fecha fe         ON fe.fecha_key = f.fecha_entrega_key
LEFT JOIN dw.dim_cliente c        ON c.cliente_key = f.cliente_key
LEFT JOIN dw.dim_producto p       ON p.producto_key = f.producto_key
LEFT JOIN dw.dim_vendedor v       ON v.vendedor_key = f.vendedor_key
LEFT JOIN dw.dim_estado_pedido e  ON e.estado_key = f.estado_key
LEFT JOIN dw.dim_pago g           ON g.pago_key = f.pago_key;

-- Claves duplicadas en la tabla de hechos. ESPERADO: 0 filas
SELECT order_id, order_item_id, COUNT(*) FROM dw.fact_ventas_item
GROUP BY order_id, order_item_id HAVING COUNT(*) > 1;

-- Claves de negocio duplicadas en dimensiones. ESPERADO: 0 filas
SELECT 'dim_cliente' AS dim, customer_unique_id AS clave, COUNT(*) FROM dw.dim_cliente GROUP BY 2 HAVING COUNT(*) > 1
UNION ALL SELECT 'dim_producto', product_id, COUNT(*) FROM dw.dim_producto GROUP BY 2 HAVING COUNT(*) > 1
UNION ALL SELECT 'dim_vendedor', seller_id,  COUNT(*) FROM dw.dim_vendedor GROUP BY 2 HAVING COUNT(*) > 1;

-- Las claves foráneas declaradas (evidencia de que existen en el modelo)
SELECT conrelid::regclass AS tabla, conname AS restriccion, pg_get_constraintdef(oid) AS definicion
FROM pg_constraint
WHERE contype IN ('p','f') AND connamespace = 'dw'::regnamespace
ORDER BY conrelid::regclass::text, contype DESC;

-- ---------- 3. VALORES NULOS RELEVANTES ----------
-- fecha_entrega_key y dias_* nulos = pedidos aún no entregados (normal).
-- review_score nulo = pedido sin reseña (normal, pocos).
SELECT COUNT(*)                                       AS filas,
       COUNT(*) FILTER (WHERE fecha_entrega_key IS NULL) AS sin_fecha_entrega,
       COUNT(*) FILTER (WHERE dias_entrega      IS NULL) AS sin_dias_entrega,
       COUNT(*) FILTER (WHERE review_score      IS NULL) AS sin_review,
       COUNT(*) FILTER (WHERE price             IS NULL) AS precio_nulo,      -- ESPERADO: 0
       COUNT(*) FILTER (WHERE freight_value     IS NULL) AS flete_nulo        -- ESPERADO: 0
FROM dw.fact_ventas_item;

-- Coherencia: pedidos 'delivered' sin fecha de entrega, o entregados con estado distinto. 
SELECT e.order_status,
       COUNT(*) AS items,
       COUNT(*) FILTER (WHERE f.fecha_entrega_key IS NULL) AS sin_fecha_entrega
FROM dw.fact_ventas_item f JOIN dw.dim_estado_pedido e USING (estado_key)
GROUP BY e.order_status ORDER BY items DESC;

-- Valores imposibles. ESPERADO: todo en 0
SELECT COUNT(*) FILTER (WHERE price < 0 OR freight_value < 0) AS montos_negativos,
       COUNT(*) FILTER (WHERE dias_entrega < 0)               AS entrega_antes_de_compra,
       COUNT(*) FILTER (WHERE review_score NOT BETWEEN 1 AND 5) AS score_fuera_de_rango
FROM dw.fact_ventas_item;

-- ---------- 4. TOTALES Y MEDIDAS PRINCIPALES ----------
SELECT COUNT(DISTINCT order_id)   AS pedidos,
       COUNT(*)                   AS items,
       ROUND(SUM(price), 2)       AS ingresos_brutos,
       ROUND(SUM(freight_value),2) AS flete_total,
       ROUND(SUM(price)/COUNT(DISTINCT order_id), 2) AS ticket_promedio_bruto,
       MIN(fc.fecha) AS primera_compra, MAX(fc.fecha) AS ultima_compra
FROM dw.fact_ventas_item f JOIN dw.dim_fecha fc ON fc.fecha_key = f.fecha_compra_key;

-- Conciliación de montos staging vs hechos. ESPERADO: diferencia = 0.00
SELECT (SELECT SUM(price) FROM stg.items)                 AS price_staging,
       (SELECT SUM(price) FROM dw.fact_ventas_item)       AS price_hechos,
       (SELECT SUM(price) FROM stg.items) - (SELECT SUM(price) FROM dw.fact_ventas_item) AS diferencia;

-- Ingresos por año-mes (debe cubrir enero 2017 - agosto 2018)
SELECT d.anio_mes, COUNT(DISTINCT f.order_id) AS pedidos, ROUND(SUM(f.price),2) AS ingresos
FROM dw.fact_ventas_item f
JOIN dw.dim_fecha d ON d.fecha_key = f.fecha_compra_key
JOIN dw.dim_estado_pedido e ON e.estado_key = f.estado_key AND e.es_ingreso_valido
GROUP BY d.anio_mes ORDER BY d.anio_mes;
