-- =====================================================================
-- 06_pruebas_objetos.sql
-- Prueba cada vista y función (evidencia de que alimentan el dashboard).
-- =====================================================================
\echo '--- KPI sin filtros (todo el período) ---'
SELECT dw.fn_total_ventas()            AS ingresos_totales,
       dw.fn_ticket_promedio()         AS ticket_promedio,
       dw.fn_tasa_entrega_a_tiempo()   AS pct_entrega_a_tiempo,
       dw.fn_tiempo_promedio_entrega() AS dias_entrega_prom,
       dw.fn_calificacion_promedio()   AS calificacion_prom,
       dw.fn_tasa_recompra()           AS pct_recompra;

\echo '--- KPI con filtros (2017, estado SP) ---'
SELECT dw.fn_total_ventas('2017-01-01','2017-12-31', NULL, 'SP')          AS ingresos_2017_sp,
       dw.fn_tasa_entrega_a_tiempo('2017-01-01','2017-12-31', NULL, 'SP') AS pct_a_tiempo_2017_sp;

\echo '--- Funciones de tabla ---'
SELECT * FROM dw.fn_ventas_mensuales('2017-01-01','2018-08-31') LIMIT 5;
SELECT * FROM dw.fn_top_categorias(NULL, NULL, NULL, 5);
SELECT * FROM dw.fn_ranking_vendedores(NULL, NULL, NULL, 5);

\echo '--- Vistas ---'
SELECT * FROM dw.v_ventas_mensual   LIMIT 5;
SELECT * FROM dw.v_ventas_categoria LIMIT 5;
SELECT * FROM dw.v_ventas_estado    LIMIT 5;
SELECT * FROM dw.v_logistica_estado LIMIT 5;
SELECT * FROM dw.v_retraso_vs_resena;
SELECT * FROM dw.v_metodos_pago     LIMIT 5;
SELECT * FROM dw.v_detalle_ventas   LIMIT 5;
