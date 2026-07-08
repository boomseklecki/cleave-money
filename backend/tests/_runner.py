"""Minimal test runner so test modules work without pytest installed in the image."""
import asyncio
import inspect


def run(namespace: dict) -> None:
    tests = sorted(
        (name, fn)
        for name, fn in namespace.items()
        if name.startswith("test_") and callable(fn)
    )
    # One event loop for all async tests so the shared async engine's pooled
    # connections stay bound to a single loop.
    loop = asyncio.new_event_loop()
    try:
        for name, fn in tests:
            if inspect.iscoroutinefunction(fn):
                loop.run_until_complete(fn())
            else:
                fn()
            print(f"ok  {name}")
    finally:
        loop.close()
    print(f"ALL PASS ({len(tests)} tests)")
