-- =====================================================================
-- 05_vistas_funciones.sql
-- Objetos SQL que alimentarán el dashboard.
--   VISTAS    : resultados fijos (sin parámetros) para gráficos y tablas.
--   FUNCIONES : reciben filtros (NULL = "todos") y devuelven un KPI o una tabla.
-- Regla del negocio: INGRESOS = SUM(price) de pedidos NO cancelados ni "no disponibles".
-- Los datos a nivel de pedido (reseña, días de entrega) se repiten en cada ítem,
-- por eso siempre se agrupa por order_id antes de promediar.
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS dw;

-- ============================ FUNCIÓN BASE ============================
-- Devuelve UNA fila por pedido aplicando los filtros. Todos los KPI se calculan sobre ella.
DROP FUNCTION IF EXISTS dw.fn_base_pedidos(DATE, DATE, TEXT, CHAR) CASCADE;
CREATE FUNCTION dw.fn_base_pedidos(p_desde DATE DEFAULT NULL, p_hasta DATE DEFAULT NULL,
                                   p_categoria TEXT DEFAULT NULL, p_estado_cliente CHAR(2) DEFAULT NULL)
RETURNS TABLE (order_id VARCHAR, cliente_key INT, fecha_compra DATE, ingresos NUMERIC, flete NUMERIC,
               n_items BIGINT, entregado BOOLEAN, dias_entrega NUMERIC, dias_retraso INT,
               entrega_a_tiempo SMALLINT, review_score NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT f.order_id, MIN(f.cliente_key), MIN(d.fecha),
           SUM(f.price), SUM(f.freight_value), COUNT(*),
           (MAX(f.fecha_entrega_key) IS NOT NULL AND MIN(e.order_status) = 'delivered'),
           MAX(f.dias_entrega), MAX(f.dias_retraso)::int, MAX(f.entrega_a_tiempo), MAX(f.review_score)
    FROM dw.fact_ventas_item f
    JOIN dw.dim_fecha d          ON d.fecha_key = f.fecha_compra_key
    JOIN dw.dim_estado_pedido e  ON e.estado_key = f.estado_key
    JOIN dw.dim_producto p       ON p.producto_key = f.producto_key
    JOIN dw.dim_cliente c        ON c.cliente_key = f.cliente_key
    WHERE e.es_ingreso_valido
      AND (p_desde IS NULL          OR d.fecha >= p_desde)
      AND (p_hasta IS NULL          OR d.fecha <= p_hasta)
      AND (p_categoria IS NULL      OR p.categoria_en = p_categoria)
      AND (p_estado_cliente IS NULL OR c.estado = p_estado_cliente)
    GROUP BY f.order_id
$$;

-- ============================== KPI (tarjetas) ==============================
CREATE OR REPLACE FUNCTION dw.fn_total_ventas(p_desde DATE DEFAULT NULL, p_hasta DATE DEFAULT NULL,
        p_categoria TEXT DEFAULT NULL, p_estado_cliente CHAR(2) DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(ROUND(SUM(ingresos), 2), 0) FROM dw.fn_base_pedidos(p_desde, p_hasta, p_categoria, p_estado_cliente)
$$;

CREATE OR REPLACE FUNCTION dw.fn_ticket_promedio(p_desde DATE DEFAULT NULL, p_hasta DATE DEFAULT NULL,
        p_categoria TEXT DEFAULT NULL, p_estado_cliente CHAR(2) DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT ROUND(AVG(ingresos), 2) FROM dw.fn_base_pedidos(p_desde, p_hasta, p_categoria, p_estado_cliente)
$$;

CREATE OR REPLACE FUNCTION dw.fn_tasa_entrega_a_tiempo(p_desde DATE DEFAULT NULL, p_hasta DATE DEFAULT NULL,
        p_categoria TEXT DEFAULT NULL, p_estado_cliente CHAR(2) DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT ROUND(100.0 * AVG(entrega_a_tiempo), 2)
    FROM dw.fn_base_pedidos(p_desde, p_hasta, p_categoria, p_estado_cliente) WHERE entregado
$$;

CREATE OR REPLACE FUNCTION dw.fn_tiempo_promedio_entrega(p_desde DATE DEFAULT NULL, p_hasta DATE DEFAULT NULL,
        p_categoria TEXT DEFAULT NULL, p_estado_cliente CHAR(2) DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT ROUND(AVG(dias_entrega), 1)
    FROM dw.fn_base_pedidos(p_desde, p_hasta, p_categoria, p_estado_cliente) WHERE entregado
$$;

CREATE OR REPLACE FUNCTION dw.fn_calificacion_promedio(p_desde DATE DEFAULT NULL, p_hasta DATE DEFAULT NULL,
        p_categoria TEXT DEFAULT NULL, p_estado_cliente CHAR(2) DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT ROUND(AVG(review_score), 2) FROM dw.fn_base_pedidos(p_desde, p_hasta, p_categoria, p_estado_cliente)
$$;

-- Tasa de recompra = clientes con más de un pedido / clientes únicos (en %)
CREATE OR REPLACE FUNCTION dw.fn_tasa_recompra(p_desde DATE DEFAULT NULL, p_hasta DATE DEFAULT NULL,
        p_categoria TEXT DEFAULT NULL, p_estado_cliente CHAR(2) DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH por_cliente AS (
        SELECT cliente_key, COUNT(*) AS pedidos
        FROM dw.fn_base_pedidos(p_desde, p_hasta, p_categoria, p_estado_cliente) GROUP BY cliente_key)
    SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE pedidos > 1) / NULLIF(COUNT(*), 0), 2) FROM por_cliente
$$;

-- ========================= FUNCIONES DE TABLA (gráficos) =========================
-- Ventas por mes (gráfico de líneas)
CREATE OR REPLACE FUNCTION dw.fn_ventas_mensuales(p_desde DATE DEFAULT NULL, p_hasta DATE DEFAULT NULL,
        p_categoria TEXT DEFAULT NULL, p_estado_cliente CHAR(2) DEFAULT NULL)
RETURNS TABLE (anio_mes TEXT, pedidos BIGINT, ingresos NUMERIC, ticket_promedio NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT to_char(fecha_compra, 'YYYY-MM'), COUNT(*), ROUND(SUM(ingresos), 2), ROUND(AVG(ingresos), 2)
    FROM dw.fn_base_pedidos(p_desde, p_hasta, p_categoria, p_estado_cliente)
    GROUP BY 1 ORDER BY 1
$$;

-- Top N categorías por ingresos (gráfico de barras)
CREATE OR REPLACE FUNCTION dw.fn_top_categorias(p_desde DATE DEFAULT NULL, p_hasta DATE DEFAULT NULL,
        p_estado_cliente CHAR(2) DEFAULT NULL, p_top INT DEFAULT 10)
RETURNS TABLE (categoria TEXT, pedidos BIGINT, ingresos NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT p.categoria_en::text, COUNT(DISTINCT f.order_id), ROUND(SUM(f.price), 2) AS ingresos
    FROM dw.fact_ventas_item f
    JOIN dw.dim_fecha d         ON d.fecha_key = f.fecha_compra_key
    JOIN dw.dim_estado_pedido e ON e.estado_key = f.estado_key AND e.es_ingreso_valido
    JOIN dw.dim_producto p      ON p.producto_key = f.producto_key
    JOIN dw.dim_cliente c       ON c.cliente_key = f.cliente_key
    WHERE (p_desde IS NULL OR d.fecha >= p_desde) AND (p_hasta IS NULL OR d.fecha <= p_hasta)
      AND (p_estado_cliente IS NULL OR c.estado = p_estado_cliente)
    GROUP BY p.categoria_en ORDER BY ingresos DESC LIMIT p_top
$$;

-- Ranking de vendedores (tabla de detalle)
CREATE OR REPLACE FUNCTION dw.fn_ranking_vendedores(p_desde DATE DEFAULT NULL, p_hasta DATE DEFAULT NULL,
        p_estado_vendedor CHAR(2) DEFAULT NULL, p_top INT DEFAULT 20)
RETURNS TABLE (seller_id TEXT, estado CHAR(2), ciudad TEXT, pedidos BIGINT, ingresos NUMERIC,
               calificacion_prom NUMERIC, pct_entregas_tarde NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH por_pedido AS (          -- un registro por (vendedor, pedido)
        SELECT f.vendedor_key, f.order_id, SUM(f.price) AS ingresos,
               MAX(f.review_score) AS review, MAX(f.entrega_a_tiempo) AS a_tiempo
        FROM dw.fact_ventas_item f
        JOIN dw.dim_fecha d         ON d.fecha_key = f.fecha_compra_key
        JOIN dw.dim_estado_pedido e ON e.estado_key = f.estado_key AND e.es_ingreso_valido
        WHERE (p_desde IS NULL OR d.fecha >= p_desde) AND (p_hasta IS NULL OR d.fecha <= p_hasta)
        GROUP BY f.vendedor_key, f.order_id)
    SELECT v.seller_id::text, v.estado, v.ciudad::text, COUNT(*), ROUND(SUM(pp.ingresos), 2) AS ingresos,
           ROUND(AVG(pp.review), 2),
           ROUND(100.0 * COUNT(*) FILTER (WHERE pp.a_tiempo = 0) / NULLIF(COUNT(pp.a_tiempo), 0), 2)
    FROM por_pedido pp JOIN dw.dim_vendedor v ON v.vendedor_key = pp.vendedor_key
    WHERE (p_estado_vendedor IS NULL OR v.estado = p_estado_vendedor)
    GROUP BY v.seller_id, v.estado, v.ciudad
    ORDER BY ingresos DESC LIMIT p_top
$$;

-- ================================ VISTAS ================================
-- Pedido-nivel sobre todo el período (base de las vistas de logística y satisfacción)
CREATE OR REPLACE VIEW dw.v_pedidos AS
SELECT * FROM dw.fn_base_pedidos(NULL, NULL, NULL, NULL);

-- Resumen de ventas por mes
CREATE OR REPLACE VIEW dw.v_ventas_mensual AS
SELECT to_char(fecha_compra, 'YYYY-MM') AS anio_mes, COUNT(*) AS pedidos,
       ROUND(SUM(ingresos), 2) AS ingresos, ROUND(SUM(flete), 2) AS flete,
       ROUND(AVG(ingresos), 2) AS ticket_promedio
FROM dw.v_pedidos GROUP BY 1 ORDER BY 1;

-- Ventas por categoría
CREATE OR REPLACE VIEW dw.v_ventas_categoria AS
SELECT p.categoria_en AS categoria, COUNT(DISTINCT f.order_id) AS pedidos, COUNT(*) AS items,
       ROUND(SUM(f.price), 2) AS ingresos
FROM dw.fact_ventas_item f
JOIN dw.dim_estado_pedido e ON e.estado_key = f.estado_key AND e.es_ingreso_valido
JOIN dw.dim_producto p      ON p.producto_key = f.producto_key
GROUP BY p.categoria_en ORDER BY ingresos DESC;

-- Ventas por estado y región del cliente (mapa / barras)
CREATE OR REPLACE VIEW dw.v_ventas_estado AS
SELECT c.region, c.estado, COUNT(DISTINCT f.order_id) AS pedidos, ROUND(SUM(f.price), 2) AS ingresos
FROM dw.fact_ventas_item f
JOIN dw.dim_estado_pedido e ON e.estado_key = f.estado_key AND e.es_ingreso_valido
JOIN dw.dim_cliente c       ON c.cliente_key = f.cliente_key
GROUP BY c.region, c.estado ORDER BY ingresos DESC;

-- Logística por estado del cliente (solo pedidos entregados)
CREATE OR REPLACE VIEW dw.v_logistica_estado AS
SELECT c.estado, COUNT(*) AS pedidos_entregados, ROUND(AVG(p.dias_entrega), 1) AS dias_entrega_prom,
       ROUND(100.0 * AVG(p.entrega_a_tiempo), 2) AS pct_entrega_a_tiempo,
       ROUND(AVG(p.dias_retraso), 2) AS dias_retraso_prom
FROM dw.v_pedidos p JOIN dw.dim_cliente c ON c.cliente_key = p.cliente_key
WHERE p.entregado GROUP BY c.estado ORDER BY pct_entrega_a_tiempo;

-- Efecto del retraso en la calificación (pregunta P3)
CREATE OR REPLACE VIEW dw.v_retraso_vs_resena AS
SELECT CASE WHEN dias_retraso = 0 THEN '1. A tiempo'
            WHEN dias_retraso <= 3 THEN '2. 1-3 días tarde'
            WHEN dias_retraso <= 7 THEN '3. 4-7 días tarde'
            ELSE '4. Más de 7 días tarde' END AS rango_retraso,
       COUNT(*) AS pedidos, ROUND(AVG(review_score), 2) AS calificacion_prom,
       ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2) / COUNT(review_score), 2) AS pct_resenas_1_2
FROM dw.v_pedidos WHERE entregado AND review_score IS NOT NULL
GROUP BY 1 ORDER BY 1;

-- Medios de pago (pregunta P5)
CREATE OR REPLACE VIEW dw.v_metodos_pago AS
SELECT g.tipo_pago, g.grupo_cuotas, COUNT(DISTINCT f.order_id) AS pedidos, ROUND(SUM(f.price), 2) AS ingresos
FROM dw.fact_ventas_item f
JOIN dw.dim_estado_pedido e ON e.estado_key = f.estado_key AND e.es_ingreso_valido
JOIN dw.dim_pago g          ON g.pago_key = f.pago_key
GROUP BY g.tipo_pago, g.grupo_cuotas, g.orden_cuotas ORDER BY g.tipo_pago, g.orden_cuotas;

-- Detalle plano a nivel de ítem (tabla de detalle del dashboard)
CREATE OR REPLACE VIEW dw.v_detalle_ventas AS
SELECT f.order_id, f.order_item_id, d.fecha AS fecha_compra, e.estado_es AS estado_pedido,
       p.categoria_en AS categoria, c.estado AS estado_cliente, c.region, v.seller_id,
       g.tipo_pago, f.price, f.freight_value, f.dias_entrega, f.dias_retraso, f.review_score
FROM dw.fact_ventas_item f
JOIN dw.dim_fecha d          ON d.fecha_key = f.fecha_compra_key
JOIN dw.dim_estado_pedido e  ON e.estado_key = f.estado_key
JOIN dw.dim_producto p       ON p.producto_key = f.producto_key
JOIN dw.dim_cliente c        ON c.cliente_key = f.cliente_key
JOIN dw.dim_vendedor v       ON v.vendedor_key = f.vendedor_key
JOIN dw.dim_pago g           ON g.pago_key = f.pago_key;
