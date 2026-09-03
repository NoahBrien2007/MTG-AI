"""Export a checkpoint to ONNX, for running the model outside Python.

    python -m mtgai.export_onnx
    python -m mtgai.export_onnx --checkpoint checkpoints/value_net_last.pt --out ../models/value_net.onnx

The graph takes a batch of `features` (float32, N × feature_count) and
`card_ids` (int64, N × total_slots) and returns `win_probability` (float32, N).
Batch size is dynamic. A sidecar `.json` with the encoding spec is written next
to the model so whatever loads it can check the layout matches.

Newer torch versions default to the dynamo exporter, which needs the extra
`onnxscript` package; this falls back to the classic TorchScript exporter when
it is missing, so no extra install is required. ONNX is only needed to run the
model outside Python — `mtgai.serve` talks to Godot without it.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
from torch import nn

from .model import ValueNet
from .paths import DEFAULT_CHECKPOINT, DEFAULT_ONNX


class _Probability(nn.Module):
    """Wraps the net so the exported graph outputs a probability, not a logit."""

    def __init__(self, model: ValueNet) -> None:
        super().__init__()
        self.model = model

    def forward(self, features: torch.Tensor, card_ids: torch.Tensor) -> torch.Tensor:
        return torch.sigmoid(self.model(features, card_ids))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--checkpoint", default=str(DEFAULT_CHECKPOINT))
    parser.add_argument("--out", default=str(DEFAULT_ONNX))
    parser.add_argument("--opset", type=int, default=17)
    args = parser.parse_args(argv)

    model = ValueNet.load(args.checkpoint)
    wrapped = _Probability(model).eval()
    spec = model.spec

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    example_features = torch.zeros(2, spec.feature_count, dtype=torch.float32)
    example_ids = torch.zeros(2, spec.total_slots, dtype=torch.int64)

    export_kwargs = dict(
        input_names=["features", "card_ids"],
        output_names=["win_probability"],
        dynamic_axes={
            "features": {0: "batch"},
            "card_ids": {0: "batch"},
            "win_probability": {0: "batch"},
        },
        opset_version=args.opset,
    )
    try:
        torch.onnx.export(wrapped, (example_features, example_ids), str(out_path), **export_kwargs)
    except Exception as error:  # noqa: BLE001 - fall back, then report clearly
        # torch >= 2.9 defaults to the dynamo exporter, which needs `onnxscript`.
        print(f"dynamo export unavailable ({type(error).__name__}); using the TorchScript exporter")
        try:
            torch.onnx.export(
                wrapped, (example_features, example_ids), str(out_path), dynamo=False, **export_kwargs
            )
        except Exception as fallback_error:  # noqa: BLE001
            print(f"\nONNX export failed: {fallback_error}")
            print("Install the optional export dependencies:  pip install onnx onnxscript")
            print("(ONNX is only needed to run the model outside Python; "
                  "`python -m mtgai.serve` works without it.)")
            return 1

    sidecar = out_path.with_suffix(".json")
    sidecar.write_text(json.dumps(spec.to_dict(), indent=1, ensure_ascii=False), encoding="utf-8")

    print(f"wrote {out_path}")
    print(f"      {sidecar}  (encoding spec + vocabulary)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
