"""
erpnext_parquet_extractor.py

Modular utility for extracting raw data from an ERPNext (Frappe/MariaDB)
database into Parquet files using SQLAlchemy. Designed to be dropped into
Airflow DAGs as a PythonOperator / TaskFlow task, but works standalone too.

Install:
    pip install sqlalchemy pymysql pandas pyarrow

Usage (standalone):
    config = ERPNextDBConfig.from_env()
    engine = get_engine(config)
    extract_table_to_parquet(engine, "tabSales Invoice", "out/sales_invoice.parquet")

Usage (Airflow):
    See `run_extraction_task` docstring at the bottom of this file.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Optional, Sequence

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

@dataclass
class ERPNextDBConfig:
    """Connection settings for the ERPNext MariaDB/MySQL database."""

    host: str
    port: int = 3306
    database: str = "erpnext"
    user: str = "root"
    password: str = ""
    driver: str = "mysql+pymysql"  # swap for "mysql+mysqlconnector" if you prefer that driver

    @classmethod
    def from_env(cls, prefix: str = "ERPNEXT_DB_") -> "ERPNextDBConfig":
        """Build config from environment variables, e.g. ERPNEXT_DB_HOST."""
        return cls(
            host=os.environ[f"{prefix}HOST"],
            port=int(os.environ.get(f"{prefix}PORT", 3306)),
            database=os.environ.get(f"{prefix}NAME", "erpnext"),
            user=os.environ[f"{prefix}USER"],
            password=os.environ[f"{prefix}PASSWORD"],
        )

    @classmethod
    def from_airflow_conn(cls, conn_id: str = "erpnext_mysql") -> "ERPNextDBConfig":
        """Build config from an Airflow Connection so secrets stay out of code."""
        from airflow.hooks.base import BaseHook  # lazy import: only needed inside Airflow

        conn = BaseHook.get_connection(conn_id)
        return cls(
            host=conn.host,
            port=conn.port or 3306,
            database=conn.schema,
            user=conn.login,
            password=conn.password,
        )

    def sqlalchemy_url(self) -> str:
        return (
            f"{self.driver}://{self.user}:{self.password}"
            f"@{self.host}:{self.port}/{self.database}"
        )


def get_engine(config: ERPNextDBConfig, **engine_kwargs) -> Engine:
    """Create a SQLAlchemy engine with sane pooling defaults for scheduled jobs."""
    return create_engine(
        config.sqlalchemy_url(),
        pool_pre_ping=True,   # avoids stale-connection errors on long-idle Airflow workers
        pool_recycle=1800,    # recycle connections every 30 min
        **engine_kwargs,
    )


# ---------------------------------------------------------------------------
# Core extraction logic
# ---------------------------------------------------------------------------

def _iter_chunks(
    engine: Engine,
    query: str,
    params: Optional[dict] = None,
    chunksize: int = 50_000,
) -> Iterator[pd.DataFrame]:
    """Yield DataFrame chunks from a SQL query without loading it all into memory."""
    with engine.connect().execution_options(stream_results=True) as conn:
        for chunk in pd.read_sql(text(query), conn, params=params, chunksize=chunksize):
            yield chunk


def extract_query_to_parquet(
    engine: Engine,
    query: str,
    output_path: str | Path,
    params: Optional[dict] = None,
    chunksize: int = 50_000,
    compression: str = "snappy",
) -> Path:
    """
    Run an arbitrary SQL query and stream results into a single Parquet file,
    writing chunk-by-chunk so large ERPNext tables (e.g. `tabGL Entry`,
    `tabStock Ledger Entry`) don't blow up worker memory.
    """
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    writer: Optional[pq.ParquetWriter] = None
    total_rows = 0
    try:
        for chunk in _iter_chunks(engine, query, params, chunksize):
            table = pa.Table.from_pandas(chunk, preserve_index=False)
            if writer is None:
                writer = pq.ParquetWriter(output_path, table.schema, compression=compression)
            writer.write_table(table)
            total_rows += len(chunk)
            logger.info("Written %s rows so far -> %s", total_rows, output_path)
    finally:
        if writer is not None:
            writer.close()

    if total_rows == 0:
        logger.warning("Query returned no rows: %s", query)

    return output_path


def extract_table_to_parquet(
    engine: Engine,
    table_name: str,
    output_path: str | Path,
    columns: Optional[Sequence[str]] = None,
    where: Optional[str] = None,
    chunksize: int = 50_000,
) -> Path:
    """
    Convenience wrapper for extracting a whole ERPNext doctype table
    (e.g. 'tabSales Invoice', 'tabCustomer') into Parquet.

    `where` lets you do incremental pulls, e.g. where="modified >= '2026-07-01'"
    """
    col_expr = ", ".join(f"`{c}`" for c in columns) if columns else "*"
    query = f"SELECT {col_expr} FROM `{table_name}`"
    if where:
        query += f" WHERE {where}"

    return extract_query_to_parquet(engine, query, output_path, chunksize=chunksize)


# ---------------------------------------------------------------------------
# Airflow entry point
# ---------------------------------------------------------------------------

def run_extraction_task(
    table_name: str,
    output_dir: str,
    conn_id: str = "erpnext_mysql",
    where: Optional[str] = None,
    **context,
) -> str:
    """
    Callable for a PythonOperator or @task in an Airflow DAG.

    Example (classic operator):

        from airflow.operators.python import PythonOperator

        extract_sales_invoice = PythonOperator(
            task_id="extract_sales_invoice",
            python_callable=run_extraction_task,
            op_kwargs={
                "table_name": "tabSales Invoice",
                "output_dir": "/data/erpnext/raw",
                "conn_id": "erpnext_mysql",
                "where": "modified >= '{{ ds }}'",
            },
        )

    Example (TaskFlow API):

        from airflow.decorators import task

        @task
        def extract_sales_invoice(ds=None):
            return run_extraction_task(
                table_name="tabSales Invoice",
                output_dir="/data/erpnext/raw",
                where=f"modified >= '{ds}'",
                ds=ds,
            )
    """
    config = ERPNextDBConfig.from_airflow_conn(conn_id)
    engine = get_engine(config)

    ds = context.get("ds") or "manual_run"
    safe_table = table_name.replace(" ", "_").lower()
    output_path = Path(output_dir) / f"{safe_table}_{ds}.parquet"

    try:
        extract_table_to_parquet(engine, table_name, output_path, where=where)
    finally:
        engine.dispose()

    return str(output_path)


if __name__ == "__main__":
    # Quick local smoke test — requires ERPNEXT_DB_* env vars to be set.
    logging.basicConfig(level=logging.INFO)
    cfg = ERPNextDBConfig.from_env()
    eng = get_engine(cfg)
    extract_table_to_parquet(eng, "tabCustomer", "out/customer.parquet")
