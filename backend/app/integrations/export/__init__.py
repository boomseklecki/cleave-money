"""User-facing data export (CSV / JSON / OFX).

The read paths (scoping, eager-loads) live in `queries.py`; the format serializers
(`csv_writer`, `json_writer`, `ofx_writer`) are pure functions over already-loaded
ORM rows; `archive.py` bundles everything into a single ZIP. Consumed by the
`app/routers/exports.py` router.
"""
