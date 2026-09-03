"""Score a trained checkpoint against a dataset.

    python -m mtgai.evaluate                              # best checkpoint, all datasets
    python -m mtgai.evaluate --checkpoint checkpoints/value_net_last.pt
    python -m mtgai.evaluate ../training/datasets/games_2026-09-04.jsonl

Prints accuracy, AUC, Brier score, a calibration table and accuracy per game
stage. A useful value network is well calibrated (predicted ≈ actual in every
row) and much more accurate late in the game than on turn one.
"""

from __future__ import annotations

import argparse

import torch

from . import metrics
from .data import load_samples
from .model import ValueNet
from .paths import DATASET_DIR, DEFAULT_CHECKPOINT
from .train import predict


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("datasets", nargs="*", default=[str(DATASET_DIR)])
    parser.add_argument("--checkpoint", default=str(DEFAULT_CHECKPOINT))
    parser.add_argument("--device", default="cpu")
    args = parser.parse_args(argv)

    samples = load_samples(args.datasets)
    print(samples.describe())

    model = ValueNet.load(args.checkpoint, map_location=args.device)
    device = torch.device(args.device)
    model.to(device)

    if not model.spec.compatible_with(samples.spec):
        print("\nERROR: the checkpoint was trained on a different encoding layout.")
        print("Re-record the datasets or retrain the model.")
        return 1

    unknown = sorted(set(samples.spec.vocabulary[1:]) - set(model.spec.vocabulary))
    if unknown:
        print(f"\nnote: {len(unknown)} card(s) unseen during training will fall back to the "
              f"empty embedding: {', '.join(unknown[:8])}{' …' if len(unknown) > 8 else ''}")

    print(f"\n{args.checkpoint}  ({model.parameter_count():,} parameters)\n")
    print(metrics.format_report(predict(model, samples, device), samples.targets, samples.turns))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
