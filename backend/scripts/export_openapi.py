"""Export the FastAPI OpenAPI schema to stdout (the canonical iOS contract).

Importing `app.main` builds the FastAPI app and introspects routes/models - it does NOT open a DB
connection - so this runs anywhere the backend deps are installed. Regenerate the iOS contract with:

    python backend/scripts/export_openapi.py > ios/openapi.json
    python3 ios/scripts/prepare_openapi.py ios/openapi.json \
        ios/CleaveAPI/Sources/CleaveAPI/openapi.json
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.main import app  # noqa: E402


def main() -> None:
    # Compact, matching what FastAPI serves at /openapi.json (the committed ios/openapi.json is minified).
    json.dump(app.openapi(), sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
