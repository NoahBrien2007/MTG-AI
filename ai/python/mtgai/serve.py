"""Tiny HTTP server that scores states, for a Godot agent to call.

    python -m mtgai.serve                       # http://127.0.0.1:8787

Endpoints
    GET  /health   -> {"ok": true, "feature_count": …, "vocab_size": …, "policy": bool}
    POST /value    -> body {"features": [...], "card_ids": [...]}
                      or   {"states": [{"features": [...], "card_ids": [...]}, ...]}
                      returns {"values": [p, ...]}  — P(the acting player wins)
    POST /policy   -> body {"states": [{"f": b64, "ids": b64, "a": b64, "n": 24}, ...]}
                      returns {"scores": [[...n logits...], ...]} — one per legal
                      action, in the order they were sent. Needs
                      --policy-checkpoint.

One request can carry many states, which matters: a searching agent evaluates
every legal action per decision, so it should send them as one batch rather
than one request each.

Only the loopback interface is bound; this is a development tool, not a service.
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np
import torch

from .model import ValueNet
from .paths import DEFAULT_CHECKPOINT
from .policy import PolicyNet

MAX_BODY_BYTES = 32 * 1024 * 1024


class _Server(ThreadingHTTPServer):
    """Quiet about clients that hang up.

    An agent that finishes a game drops its socket without a graceful close, so
    the reader thread sees a reset. That is normal client behaviour, not a
    server error, and a full traceback per game buries the actual output.
    """

    def handle_error(self, request, client_address) -> None:
        if isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


class _Handler(BaseHTTPRequestHandler):
    model: ValueNet | None = None
    policy: PolicyNet | None = None
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
            spec = (self.model or self.policy).spec
            self._send(200, {
                "ok": True,
                "feature_count": spec.feature_count,
                "total_slots": spec.total_slots,
                "vocab_size": spec.vocab_size,
                "value": self.model is not None,
                "policy": self.policy is not None,
            })
        else:
            self._send(404, {"error": f"no route {self.path}"})

    def do_POST(self) -> None:  # noqa: N802 - stdlib signature
        route = self.path.rstrip("/")
        if route not in ("/value", "/policy"):
            self._send(404, {"error": f"no route {self.path}"})
            return

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY_BYTES:
            self._send(400, {"error": "missing or oversized body"})
            return

        try:
            request = json.loads(self.rfile.read(length))
            states = request.get("states") or [request]
            payload = {"values": self._score(states)} if route == "/value" \
                else {"scores": self._score_policy(states)}
        except Exception as error:  # a bad request should not kill the server
            self._send(400, {"error": f"{type(error).__name__}: {error}"})
            return

        self._send(200, payload)

    # --------------------------------------------------------------- model

    @staticmethod
    def _decode(state: dict, spec) -> tuple[np.ndarray, np.ndarray]:
        """One state, from either the base64 form or plain JSON numbers."""
        if "f" in state:
            # Raw little-endian bytes: what the Godot agents send. Formatting
            # 1295 floats as JSON text costs more on the Godot side than the
            # forward pass costs here.
            vector = np.frombuffer(base64.b64decode(state["f"]), dtype="<f4")
            ids = np.frombuffer(base64.b64decode(state["ids"]), dtype="<i4").astype(np.int64)
        else:
            vector = np.asarray(state["features"], dtype=np.float32)
            ids = np.asarray(state["card_ids"], dtype=np.int64)
        if vector.shape[0] != spec.feature_count:
            raise ValueError(f"expected {spec.feature_count} features, got {vector.shape[0]}")
        if ids.shape[0] != spec.total_slots:
            raise ValueError(f"expected {spec.total_slots} card ids, got {ids.shape[0]}")
        # A card the model never saw maps to 0 (the "unknown" embedding);
        # clamping to vocab_size - 1 would silently mean a different card.
        return vector, np.where((ids < 0) | (ids >= spec.vocab_size), 0, ids)

    def _score_policy(self, states: list[dict]) -> list[list[float]]:
        """A logit per legal action, in the order they were sent."""
        if self.policy is None:
            raise ValueError("no policy loaded — restart with --policy-checkpoint")
        spec = self.policy.spec
        counts = [int(state["n"]) for state in states]
        width = max(counts)

        features = np.zeros((len(states), spec.feature_count), dtype=np.float32)
        card_ids = np.zeros((len(states), spec.total_slots), dtype=np.int64)
        actions = np.zeros((len(states), width, spec.action_features), dtype=np.float32)
        mask = np.zeros((len(states), width), dtype=bool)

        for row, state in enumerate(states):
            features[row], card_ids[row] = self._decode(state, spec)
            if "a" in state:
                flat = np.frombuffer(base64.b64decode(state["a"]), dtype="<f4")
            else:
                flat = np.asarray(state["actions"], dtype=np.float32).ravel()
            n = counts[row]
            if flat.size != n * spec.action_features:
                raise ValueError(
                    f"state {row}: {flat.size} action floats for {n} actions "
                    f"of {spec.action_features}"
                )
            actions[row, :n] = flat.reshape(n, spec.action_features)
            mask[row, :n] = True

        with torch.no_grad():
            logits = self.policy(
                torch.from_numpy(features).to(self.device),
                torch.from_numpy(card_ids).to(self.device),
                torch.from_numpy(actions).to(self.device),
                torch.from_numpy(mask).to(self.device),
            ).cpu()
        return [[round(float(v), 6) for v in logits[row, : counts[row]]] for row in range(len(states))]

    def _score(self, states: list[dict]) -> list[float]:
        if self.model is None:
            raise ValueError("no value net loaded — restart with --checkpoint")
        spec = self.model.spec
        features = np.zeros((len(states), spec.feature_count), dtype=np.float32)
        card_ids = np.zeros((len(states), spec.total_slots), dtype=np.int64)

        for row, state in enumerate(states):
            features[row], card_ids[row] = self._decode(state, spec)

        with torch.no_grad():
            probabilities = self.model.win_probability(
                torch.from_numpy(features).to(self.device),
                torch.from_numpy(card_ids).to(self.device),
            )
        return [round(float(p), 6) for p in probabilities.cpu()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--checkpoint", default=str(DEFAULT_CHECKPOINT),
                        help="value net; skipped when the file does not exist")
    parser.add_argument("--policy-checkpoint", default="",
                        help="policy net, for POST /policy")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--verbose", action="store_true", help="log every request")
    args = parser.parse_args(argv)

    _Handler.device = torch.device(args.device)
    _Handler.verbose = args.verbose

    if Path(args.checkpoint).exists():
        _Handler.model = ValueNet.load(args.checkpoint, map_location=args.device)
        _Handler.model.to(_Handler.device)
    if args.policy_checkpoint:
        _Handler.policy = PolicyNet.load(args.policy_checkpoint, map_location=args.device)
        _Handler.policy.to(_Handler.device)
    if _Handler.model is None and _Handler.policy is None:
        print(f"nothing to serve: no value net at {args.checkpoint}, no --policy-checkpoint")
        return 1

    server = _Server((args.host, args.port), _Handler)
    print(f"serving on http://{args.host}:{args.port}")
    if _Handler.model is not None:
        print(f"  POST /value   {args.checkpoint}")
    if _Handler.policy is not None:
        print(f"  POST /policy  {args.policy_checkpoint}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
