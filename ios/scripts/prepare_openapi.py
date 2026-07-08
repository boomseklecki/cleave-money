#!/usr/bin/env python3
"""Transform the canonical OpenAPI contract into a swift-openapi-generator-friendly copy.

FastAPI/Pydantic emit OpenAPI 3.1 nullable fields as ``anyOf: [{...}, {"type": "null"}]``.
swift-openapi-generator (as of 1.12) does not understand the ``{"type": "null"}`` branch and
silently *drops the whole property/parameter* — which would lose fields the app depends on
(transaction_id, splitwise_expense_id, plaid_transaction_id, category, archived_at, since/until...).

This script collapses every ``anyOf`` that contains a null branch into its single non-null schema
(or, if several non-null branches remain, an ``anyOf`` without the null), and removes the field from
its object's ``required`` list so it generates as an optional that decodes JSON ``null`` as ``nil``.

It also collapses the money ``anyOf: [{number}, {string, pattern}]`` (Pydantic ``Decimal`` request
fields like ``ExpenseCreate.amount`` / ``SplitInput.paid_share``) to its **string** member, so those
generate as plain ``String`` — trivial to build from a Swift ``Decimal`` — instead of a generated
union wrapper. (Responses are already strings.)

Usage:
    python3 ios/scripts/prepare_openapi.py ios/openapi.json \
        ios/CleaveAPI/Sources/CleaveAPI/openapi.json
"""
import json
import sys


def _is_null_schema(member):
    return isinstance(member, dict) and member.get("type") == "null"


def _is_nullable_anyof(schema):
    return (
        isinstance(schema, dict)
        and isinstance(schema.get("anyOf"), list)
        and any(_is_null_schema(m) for m in schema["anyOf"])
    )


def collapse_nullable(schema):
    """Collapse a nullable ``anyOf`` wrapper into its non-null schema, preserving metadata."""
    if not _is_nullable_anyof(schema):
        return schema
    non_null = [m for m in schema["anyOf"] if not _is_null_schema(m)]
    if len(non_null) == 1:
        collapsed = dict(non_null[0])
        for key in ("title", "default", "description"):
            if key in schema and key not in collapsed:
                collapsed[key] = schema[key]
        return collapsed
    collapsed = {k: v for k, v in schema.items() if k != "anyOf"}
    collapsed["anyOf"] = non_null
    return collapsed


def _is_money_anyof(schema):
    """A two-branch ``anyOf`` of one numeric and one string schema (Pydantic Decimal field)."""
    if not (isinstance(schema, dict) and isinstance(schema.get("anyOf"), list)):
        return False
    members = schema["anyOf"]
    if len(members) != 2 or not all(isinstance(m, dict) for m in members):
        return False
    types = {m.get("type") for m in members}
    return types in ({"number", "string"}, {"integer", "string"})


def collapse_money(schema):
    """Collapse a number|string money ``anyOf`` to its string member, preserving metadata."""
    if not _is_money_anyof(schema):
        return schema
    string_member = next(m for m in schema["anyOf"] if m.get("type") == "string")
    collapsed = dict(string_member)
    for key in ("title", "default", "description"):
        if key in schema and key not in collapsed:
            collapsed[key] = schema[key]
    return collapsed


def simplify(schema):
    """Drop a null branch, then collapse a number|string money union to string."""
    return collapse_money(collapse_nullable(schema))


def walk(node):
    if isinstance(node, dict):
        props = node.get("properties")
        if isinstance(props, dict):
            for name, subschema in list(props.items()):
                was_nullable = _is_nullable_anyof(subschema)
                props[name] = simplify(subschema)
                if was_nullable:
                    required = node.get("required")
                    if isinstance(required, list) and name in required:
                        required.remove(name)
            if isinstance(node.get("required"), list) and not node["required"]:
                del node["required"]
        if "schema" in node and isinstance(node["schema"], dict):
            node["schema"] = simplify(node["schema"])
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <input openapi.json> <output openapi.json>")
    src, dst = sys.argv[1], sys.argv[2]
    with open(src) as fh:
        doc = json.load(fh)
    walk(doc)
    with open(dst, "w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    print(f"wrote {dst}")


if __name__ == "__main__":
    main()
