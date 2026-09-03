"""Tiny HTTP server that scores states, for a Godot agent to call.

    python -m mtgai.serve                       # http://127.0.0.1:8787

Endpoints
    GET  /health   -> {"ok": true, "feature_count": …, "vocab_size": …}
    POST /value    -> body {"features": [...], "card_ids": [...]}
                      or   {"states": [{"features": [...], "card_ids": [...]}, ...]}
                      returns {"values": [p, ...]}  — P(the acting player wins)

One request can carry many states, which matters: a searching agent evaluates
every legal action per decision, so it should send them as one batch rather
than one request each.

Only the loopback interface is bound; this is a development tool, not a service.
"""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import torch

from .model import ValueNet
from .paths import DEFAULT_CHECKPOINT

MAX_BODY_BYTES = 32 * 1024 * 1024


class _Handler(BaseHTTPRequestHandler):
    model: ValueNet
    device: torch.device
    verbose: bool = False

    protocol_version = "HTTP/1.1"

    # ------------------------------------------------------------- plumbing

    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:  # noqa: A002 - stdlib signature
        if self.verbose:
            super().log_message(fmt, *args)

    # -------------------------------------------------------------- routes

    def do_GET(self) -> None:  # noqa: N802 - stdlib signature
        if self.path.rstrip("/") in ("", "/health"):
            spec = self.model.spec
            self._send(200, {
                "ok": True,
                "feature_count": spec.feature_count,
                "total_slots": spec.total_slots,
                "vocab_size": spec.vocab_size,
            })
        else:
            self._send(404, {"error": f"no route {self.path}"})

    def do_POST(self) -> None:  # noqa: N802 - stdlib signature
        if self.path.rstrip("/") != "/value":
            self._send(404, {"error": f"no route {self.path}"})
            return

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY_BYTES:
            self._send(400, {"error": "missing or oversized body"})
            return

        try:
            request = json.loads(self.rfile.read(length))
            states = request.get("states") or [request]
            values = self._score(states)
        except Exception as error:  # a bad request should not kill the server
            self._send(400, {"error": f"{type(error).__name__}: {error}"})
            return

        self._send(200, {"values": values})

    # --------------------------------------------------------------- model

    def _score(self, states: list[dict]) -> list[float]:
        spec = self.model.spec
        features = np.zeros((len(states), spec.feature_count), dtype=np.float32)
        card_ids = np.zeros((len(states), spec.total_slots), dtype=np.int64)

        for row, state in enumerate(states):
            vector = np.asarray(state["features"], dtype=np.float32)
            ids = np.asarray(state["card_ids"], dtype=np.int64)
            if vector.shape[0] != spec.feature_count:
                raise ValueError(f"state {row}: expected {spec.feature_count} features, got {vector.shape[0]}")
            if ids.shape[0] != spec.total_slots:
                raise ValueError(f"state {row}: expected {spec.total_slots} card ids, got {ids.shape[0]}")
            features[row] = vector
            # A card the model never saw maps to 0 (the "unknown" embedding);
            # clamping to vocab_size - 1 would silently mean a different card.
            card_ids[row] = np.where((ids < 0) | (ids >= spec.vocab_size), 0, ids)

        with torch.no_grad():
            probabilities = self.model.win_probability(
                torch.from_numpy(features).to(self.device),
                torch.from_numpy(card_ids).to(self.device),
            )
        return [round(float(p), 6) for p in probabilities.cpu()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--checkpoint", default=str(DEFAULT_CHECKPOINT))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--verbose", action="store_true", help="log every request")
    args = parser.parse_args(argv)

    _Handler.model = ValueNet.load(args.checkpoint, map_location=args.device)
    _Handler.device = torch.device(args.device)
    _Handler.verbose = args.verbose
    _Handler.model.to(_Handler.device)

    server = ThreadingHTTPServer((args.host, args.port), _Handler)
    print(f"value net serving on http://{args.host}:{args.port}  ({args.checkpoint})")
    print("POST /value  {\"states\": [{\"features\": [...], \"card_ids\": [...]}]}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
