"""Game systems added after the original protocol (profiles, market v2, quests, cargo rain,
archaeology, combat, loans, auctions, news, earthquakes).

Each module exposes `install(api: Api)`. Endpoints are plain functions `fn(conn, hid, form) -> dict`
registered with `api.endpoint(path)`; the framework authenticates the session, opens a DB
connection in a worker thread, converts `econ.GameError` into an error response and compresses
the result like the legacy endpoints (zlib JSON).
"""
from __future__ import annotations

import types

from fastapi import Request
from starlette.concurrency import run_in_threadpool

import econ


class Api:
    def __init__(self, app, helpers: types.SimpleNamespace):
        self.app = app
        self.h = helpers

    def endpoint(self, path: str, *, feature: str | None = None, auth: bool = True):
        h = self.h

        def deco(fn):
            async def handler(request: Request):
                _, form = await h.read_form(request)
                hid = h.hid_from_sid(form.get("sid", "")) if auth else ""
                if auth and not hid:
                    return h.zlib_resp({"err": 1, "code": "auth", "msg": "Please sign in again."})
                if feature and not econ.feature(feature):
                    return h.zlib_resp({"err": 1, "code": "disabled", "msg": "This feature is not enabled."})

                def work():
                    with h.get_db() as conn:
                        try:
                            out = fn(conn, hid, form)
                            if conn.in_transaction:
                                conn.commit()
                            return out
                        except econ.GameError as e:
                            if conn.in_transaction:
                                conn.rollback()
                            return e.resp()
                return h.zlib_resp(await run_in_threadpool(work))
            handler.__name__ = fn.__name__
            self.app.add_api_route(path, handler, methods=["POST"])
            return fn
        return deco


def install_all(app, helpers) -> list[str]:
    """Register every system's endpoints. Returns the module names installed."""
    import importlib
    api = Api(app, helpers)
    installed = []
    for name in SYSTEMS:
        mod = importlib.import_module(f"{__name__}.{name}")
        mod.install(api)
        installed.append(name)
    return installed


# Order matters only for documentation; modules are independent.
SYSTEMS = ["notify", "social", "market", "cargo", "quests", "archaeology", "combat", "loans", "auctions", "incidents", "news", "rankings", "achievements", "buildings_info", "account"]


def int_arg(form, name, default=None, lo=None, hi=None) -> int:
    try:
        v = int(float(form.get(name, default)))
    except (TypeError, ValueError):
        raise econ.GameError("bad_input", f"Invalid {name}")
    if lo is not None and v < lo or hi is not None and v > hi:
        raise econ.GameError("bad_input", f"{name} out of range")
    return v


def float_arg(form, name, default=None, lo=None, hi=None) -> float:
    try:
        v = float(form.get(name, default))
    except (TypeError, ValueError):
        raise econ.GameError("bad_input", f"Invalid {name}")
    if v != v or v in (float("inf"), float("-inf")):
        raise econ.GameError("bad_input", f"Invalid {name}")
    if lo is not None and v < lo or hi is not None and v > hi:
        raise econ.GameError("bad_input", f"{name} out of range")
    return v
