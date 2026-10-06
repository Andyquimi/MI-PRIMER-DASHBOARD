"""
etl_olist.py  -  LIMPIEZA + TRANSFORMACIÓN + CARGA A STAGING (PostgreSQL)

Qué hace (en orden):
  1. Lee los 9 CSV originales de Olist desde  data/raw/
  2. Limpia y transforma (cada paso queda registrado en docs/log_transformaciones.csv)
  3. Guarda los CSV limpios en  data/limpio/
  4. Crea el esquema "stg" en PostgreSQL (sql/01_staging.sql) y carga los datos limpios

Uso:
    python python/etl_olist.py                 # limpia y carga en PostgreSQL
    python python/etl_olist.py --solo-limpiar  # solo limpia (no toca la base de datos)

Requisitos:  pip install pandas psycopg2-binary
"""
import argparse
import csv
import io
import os
import sys
from pathlib import Path

import pandas as pd

BASE = Path(__file__).resolve().parent.parent
RAW, LIMPIO, DOCS, SQLDIR = BASE / "data" / "raw", BASE / "data" / "limpio", BASE / "docs", BASE / "sql"

# Conexión (coincide con docker-compose.yml). Se puede cambiar con variables de entorno.
DB = dict(host=os.getenv("PGHOST", "localhost"), port=int(os.getenv("PGPORT", "5432")),
          dbname=os.getenv("PGDATABASE", "bi_database"), user=os.getenv("PGUSER", "bi_user"),
          password=os.getenv("PGPASSWORD", "bi_password"))

# Período de análisis definido en el entregable 1: enero 2017 - agosto 2018
FECHA_MIN, FECHA_MAX = pd.Timestamp("2017-01-01"), pd.Timestamp("2018-08-31 23:59:59")

ARCHIVOS = {
    "orders": "olist_orders_dataset.csv", "items": "olist_order_items_dataset.csv",
    "payments": "olist_order_payments_dataset.csv", "reviews": "olist_order_reviews_dataset.csv",
    "customers": "olist_customers_dataset.csv", "sellers": "olist_sellers_dataset.csv",
    "products": "olist_products_dataset.csv", "geo": "olist_geolocation_dataset.csv",
    "trans": "product_category_name_translation.csv",
}

LOG = []


def registrar(paso, tabla, antes, despues, detalle):
    """Guarda y muestra una transformación (para documentarla en el informe)."""
    LOG.append(dict(paso=paso, tabla=tabla, filas_antes=antes, filas_despues=despues, detalle=detalle))
    print(f"[{paso:>2}] {tabla:<10} {antes:>9,} -> {despues:>9,}  {detalle}")


def normalizar_texto(serie):
    """minúsculas, sin acentos, sin espacios sobrantes."""
    return (serie.astype("string").str.normalize("NFKD").str.encode("ascii", "ignore").str.decode("ascii")
            .str.lower().str.replace(r"\s+", " ", regex=True).str.strip())


def zip_texto(serie):
    """El código postal es TEXTO de 5 caracteres (si se lee como número pierde ceros iniciales)."""
    return serie.astype("string").str.strip().str.zfill(5)


def leer():
    faltan = [f for f in ARCHIVOS.values() if not (RAW / f).exists()]
    if faltan:
        sys.exit("ERROR: faltan estos archivos en data/raw/:\n  - " + "\n  - ".join(faltan) +
                 "\nDescárgalos de Kaggle (olistbr/brazilian-ecommerce) y descomprímelos en esa carpeta.")
    zips = {"customer_zip_code_prefix": "string", "seller_zip_code_prefix": "string",
            "geolocation_zip_code_prefix": "string"}
    return {k: pd.read_csv(RAW / v, dtype=zips) for k, v in ARCHIVOS.items()}


def limpiar(d):
    # ---------------------------------------------------------------- PEDIDOS
    o = d["orders"].copy()
    n0 = len(o)
    for c in ["order_purchase_timestamp", "order_approved_at", "order_delivered_carrier_date",
              "order_delivered_customer_date", "order_estimated_delivery_date"]:
        o[c] = pd.to_datetime(o[c], errors="coerce")
    registrar(1, "orders", n0, len(o), "Fechas convertidas de texto a datetime")

    n = len(o)
    o = o.drop_duplicates("order_id")
    registrar(2, "orders", n, len(o), "Eliminados order_id duplicados")

    n = len(o)
    o = o[o.order_purchase_timestamp.between(FECHA_MIN, FECHA_MAX)]
    registrar(3, "orders", n, len(o), "Período de análisis: 2017-01-01 a 2018-08-31 (se descarta 2016 y sep-oct 2018)")

    n = len(o)
    incoherente = o.order_delivered_customer_date < o.order_purchase_timestamp
    o = o[~incoherente]
    registrar(4, "orders", n, len(o), "Descartados pedidos con fecha de entrega ANTERIOR a la compra")

    o["order_status"] = o.order_status.str.strip().str.lower()
    registrar(5, "orders", len(o), len(o), "Estado normalizado (minúsculas); fechas nulas se mantienen en pedidos no entregados")

    # ------------------------------------------------------------------ ITEMS
    i = d["items"].copy()
    n0 = len(i)
    i = i.drop_duplicates(["order_id", "order_item_id"])
    i = i[i.order_id.isin(o.order_id)]
    i["shipping_limit_date"] = pd.to_datetime(i.shipping_limit_date, errors="coerce")
    registrar(6, "items", n0, len(i), "Solo ítems de pedidos del período; fecha convertida a datetime")
    q1, q3 = i.price.quantile([.25, .75])
    atipicos = int((i.price > q3 + 1.5 * (q3 - q1)).sum())
    registrar(7, "items", len(i), len(i), f"Valores atípicos de price detectados (boxplot/IQR): {atipicos:,}. Se CONSERVAN (son precios altos legítimos)")

    # --------------------------------------------------------------- CLIENTES
    c = d["customers"].copy()
    n0 = len(c)
    c = c.drop_duplicates("customer_id")
    c = c[c.customer_id.isin(o.customer_id)]
    c["ciudad"] = normalizar_texto(c.customer_city)
    c["estado"] = c.customer_state.str.strip().str.upper()
    c["zip_prefix"] = zip_texto(c.customer_zip_code_prefix)
    c = c[["customer_id", "customer_unique_id", "zip_prefix", "ciudad", "estado"]]
    registrar(8, "customers", n0, len(c), "Solo clientes con pedidos; ciudad normalizada (minúsculas, sin acentos); zip como texto")

    # -------------------------------------------------------------- VENDEDORES
    s = d["sellers"].copy()
    n0 = len(s)
    s = s.drop_duplicates("seller_id")
    s["ciudad"] = normalizar_texto(s.seller_city)
    s["estado"] = s.seller_state.str.strip().str.upper()
    s["zip_prefix"] = zip_texto(s.seller_zip_code_prefix)
    s = s[["seller_id", "zip_prefix", "ciudad", "estado"]]
    registrar(9, "sellers", n0, len(s), "Ciudad normalizada; zip como texto")

    # --------------------------------------------------------------- PRODUCTOS
    p = d["products"].copy()
    n0 = len(p)
    p = p.drop_duplicates("product_id")
    t = d["trans"].drop_duplicates("product_category_name")
    p = p.merge(t, on="product_category_name", how="left")
    manual = {"pc_gamer": "pc_gamer",
              "portateis_cozinha_e_preparadores_de_alimentos": "portable_kitchen_food_preparers"}
    p["product_category_name_english"] = p.product_category_name_english.fillna(
        p.product_category_name.map(manual))
    sin_cat = int(p.product_category_name.isna().sum())
    sin_trad = int((p.product_category_name.notna() & p.product_category_name_english.isna()).sum())
    p["categoria_pt"] = p.product_category_name.fillna("sin_categoria")
    p["categoria_en"] = p.product_category_name_english.fillna(p.categoria_pt)
    for col in ["product_weight_g", "product_length_cm", "product_height_cm", "product_width_cm"]:
        p.loc[p[col] <= 0, col] = float("nan")                     # medidas 0 no son reales
    p = p.rename(columns={"product_weight_g": "peso_g", "product_length_cm": "largo_cm",
                          "product_height_cm": "alto_cm", "product_width_cm": "ancho_cm"})
    p = p[["product_id", "categoria_pt", "categoria_en", "peso_g", "largo_cm", "alto_cm", "ancho_cm"]]
    # productos que aparecen en items pero no en el catálogo (por seguridad)
    faltan = set(i.product_id) - set(p.product_id)
    if faltan:
        extra = pd.DataFrame({"product_id": sorted(faltan), "categoria_pt": "sin_categoria",
                              "categoria_en": "sin_categoria"})
        p = pd.concat([p, extra], ignore_index=True)
    registrar(10, "products", n0, len(p), f"Unido con traducción de categorías; {sin_cat} sin categoría -> 'sin_categoria'; "
                                          f"{sin_trad} sin traducción; columnas renombradas (se corrigen errores ortográficos)")

    # ------------------------------------------------------------------ PAGOS
    pg = d["payments"].copy()
    n0 = len(pg)
    pg = pg[pg.order_id.isin(o.order_id)]
    pg.loc[~pg.payment_type.isin(["credit_card", "boleto", "voucher", "debit_card"]), "payment_type"] = "not_defined"
    principal = (pg.sort_values(["order_id", "payment_value"], ascending=[True, False])
                   .drop_duplicates("order_id")[["order_id", "payment_type"]]
                   .rename(columns={"payment_type": "tipo_pago_principal"}))
    resumen = pg.groupby("order_id").agg(cuotas_max=("payment_installments", "max"),
                                         valor_total_pago=("payment_value", "sum"),
                                         n_pagos=("payment_sequential", "count")).reset_index()
    pg = principal.merge(resumen, on="order_id")
    pg["cuotas_max"] = pg.cuotas_max.astype("Int64")
    pg["n_pagos"] = pg.n_pagos.astype("Int64")
    registrar(11, "payments", n0, len(pg), "Pagos resumidos a UNA fila por pedido (tipo principal = el de mayor valor; cuotas = máximo)")

    # ---------------------------------------------------------------- RESEÑAS
    r = d["reviews"].copy()
    n0 = len(r)
    r["review_answer_timestamp"] = pd.to_datetime(r.review_answer_timestamp, errors="coerce")
    r = r[r.order_id.isin(o.order_id)]
    r = (r.sort_values(["order_id", "review_answer_timestamp"], ascending=[True, False])
           .drop_duplicates("order_id")[["order_id", "review_score"]])
    r = r[r.review_score.between(1, 5)]
    r["review_score"] = r.review_score.astype(int)
    registrar(12, "reviews", n0, len(r), "Una reseña por pedido (la más reciente); comentarios de texto excluidos (88 % / 59 % vacíos)")

    # ----------------------------------------------------------- GEOLOCALIZACIÓN
    g = d["geo"].copy()
    n0 = len(g)
    g["zip_prefix"] = zip_texto(g.geolocation_zip_code_prefix)
    g = g[g.geolocation_lat.between(-34, 6) & g.geolocation_lng.between(-74, -34)]   # dentro de Brasil
    g = (g.groupby("zip_prefix").agg(lat=("geolocation_lat", "mean"), lng=("geolocation_lng", "mean"))
           .round(6).reset_index())
    registrar(13, "geoloc", n0, len(g), "De-duplicada: UN punto por código postal (promedio de coordenadas)")

    # Tablas finales con los nombres de staging
    o = o.rename(columns={"order_purchase_timestamp": "purchase_ts", "order_approved_at": "approved_ts",
                          "order_delivered_carrier_date": "delivered_carrier_ts",
                          "order_delivered_customer_date": "delivered_customer_ts",
                          "order_estimated_delivery_date": "estimated_delivery_ts"})
    o = o[["order_id", "customer_id", "order_status", "purchase_ts", "approved_ts", "delivered_carrier_ts",
           "delivered_customer_ts", "estimated_delivery_ts"]]
    i = i.rename(columns={"shipping_limit_date": "shipping_limit_ts"})
    i = i[["order_id", "order_item_id", "product_id", "seller_id", "shipping_limit_ts", "price", "freight_value"]]
    return {"pedidos": o, "items": i, "clientes": c, "vendedores": s, "productos": p,
            "pagos_pedido": pg, "resenas": r, "geolocalizacion": g}


def guardar_csv(tablas):
    LIMPIO.mkdir(parents=True, exist_ok=True)
    for nombre, df in tablas.items():
        df.to_csv(LIMPIO / f"{nombre}.csv", index=False)
    DOCS.mkdir(parents=True, exist_ok=True)
    pd.DataFrame(LOG).to_csv(DOCS / "log_transformaciones.csv", index=False, encoding="utf-8-sig")
    print(f"\nCSV limpios guardados en {LIMPIO}\nLog de transformaciones en {DOCS / 'log_transformaciones.csv'}")


def cargar_postgres(tablas):
    import psycopg2
    print("\nConectando a PostgreSQL ...")
    try:
        con = psycopg2.connect(**DB)
    except Exception as e:
        sys.exit(f"ERROR de conexión: {e}\n¿Está el contenedor encendido? (docker compose up -d)")
    cur = con.cursor()
    cur.execute((SQLDIR / "01_staging.sql").read_text(encoding="utf-8"))
    for nombre, df in tablas.items():
        buf = io.StringIO()
        df.to_csv(buf, index=False, header=False, na_rep="", quoting=csv.QUOTE_MINIMAL)
        buf.seek(0)
        cols = ", ".join(df.columns)
        cur.copy_expert(f"COPY stg.{nombre} ({cols}) FROM STDIN WITH (FORMAT csv, NULL '')", buf)
        cur.execute(f"SELECT COUNT(*) FROM stg.{nombre}")
        print(f"  stg.{nombre:<16} {cur.fetchone()[0]:>9,} filas cargadas")
    con.commit()
    con.close()
    print("Staging cargado correctamente.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--solo-limpiar", action="store_true", help="no carga a PostgreSQL")
    a = ap.parse_args()
    tablas = limpiar(leer())
    guardar_csv(tablas)
    if not a.solo_limpiar:
        cargar_postgres(tablas)
