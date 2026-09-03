"""Self-checks for the training pipeline — no Godot, no recordings needed.

    python -m mtgai.selftest

Verifies the things that break silently: tensor shapes, that empty card slots
are genuinely ignored, that slot order inside a zone does not change the
prediction, that merging datasets with different card-id orders keeps cards
aligned, and that a checkpoint round-trips exactly.
"""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

import numpy as np
import torch

from .data import load_samples, split_by_game
from .metrics import auc, accuracy, brier
from .model import ModelConfig, ValueNet
from .spec import EncodingSpec
from .testdata import synthetic_samples, write_synthetic_dataset

_checks = 0


def check(condition: bool, message: str) -> None:
    global _checks
    _checks += 1
    if not condition:
        raise AssertionError(message)
    print(f"  ok  {message}")


def test_spec() -> None:
    print("spec")
    spec = EncodingSpec()
    check(spec.total_slots == 37, "37 card slots (10 hand + 12 + 12 battlefield + 3 stack)")
    check(spec.feature_count == 1110, f"1110 features, got {spec.feature_count}")
    check([name for name, _, _ in spec.zone_bounds()][1] == "my_battlefield", "zone order")

    spec = EncodingSpec()
    remap = spec.merge_vocabulary(["", "Opt", "Island"])
    check(remap[1] == spec.card_id("Opt"), "merge_vocabulary remaps ids by name")
    remap2 = spec.merge_vocabulary(["", "Island", "Opt"])
    check(remap2[1] == spec.card_id("Island") and remap2[2] == spec.card_id("Opt"),
          "a second file with a different id order remaps correctly")
    check(spec.vocab_size == 3, "no duplicate card names after merging")


def test_model_shapes() -> None:
    print("model")
    samples = synthetic_samples(games=6, seed=3)
    model = ValueNet(samples.spec, ModelConfig(dropout=0.0)).eval()

    features = torch.from_numpy(samples.features[:8])
    card_ids = torch.from_numpy(samples.card_ids[:8])
    logits = model(features, card_ids)
    check(logits.shape == (8,), f"one logit per state, got {tuple(logits.shape)}")

    probabilities = model.win_probability(features, card_ids)
    check(bool(((probabilities >= 0) & (probabilities <= 1)).all()), "probabilities in [0, 1]")

    empty = torch.zeros(1, samples.spec.feature_count)
    empty_ids = torch.zeros(1, samples.spec.total_slots, dtype=torch.long)
    check(torch.isfinite(model(empty, empty_ids)).all().item(),
          "an all-empty state produces a finite logit (masked pooling)")


def test_permutation_invariance() -> None:
    print("permutation invariance")
    samples = synthetic_samples(games=4, seed=5)
    spec = samples.spec
    model = ValueNet(spec, ModelConfig(dropout=0.0)).eval()

    row = samples.features[:1].copy()
    ids = samples.card_ids[:1].copy()
    _, start, end = spec.zone_bounds()[1]  # my battlefield

    def slot_view(vector: np.ndarray, slot: int) -> np.ndarray:
        base = spec.global_features + slot * spec.card_features
        return vector[0, base : base + spec.card_features]

    original = float(model(torch.from_numpy(row), torch.from_numpy(ids))[0])

    shuffled_row, shuffled_ids = row.copy(), ids.copy()
    order = list(range(start, end))[::-1]
    for target, source in zip(range(start, end), order):
        slot_view(shuffled_row, target)[:] = slot_view(row, source)
        shuffled_ids[0, target] = ids[0, source]
    reversed_value = float(model(torch.from_numpy(shuffled_row), torch.from_numpy(shuffled_ids))[0])

    check(abs(original - reversed_value) < 1e-4,
          f"reordering slots within a zone leaves the value unchanged ({original:.6f} vs {reversed_value:.6f})")


def test_dataset_round_trip() -> None:
    print("dataset round trip")
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        write_synthetic_dataset(directory / "one.jsonl", games=8, seed=11)

        # Second file, same cards but a shuffled vocabulary.
        text = (directory / "one.jsonl").read_text(encoding="utf-8").splitlines()
        header = json.loads(text[0])
        names = header["vocabulary"][1:]
        shuffled = [""] + names[::-1]
        remap = {i: shuffled.index(n) for i, n in enumerate(header["vocabulary"]) if n}
        remap[0] = 0
        header["vocabulary"] = shuffled
        lines = [json.dumps(header)]
        for line in text[1:]:
            sample = json.loads(line)
            sample["card_ids"] = [remap[i] for i in sample["card_ids"]]
            lines.append(json.dumps(sample))
        (directory / "two.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")

        merged = load_samples([directory], verbose=False)
        half = len(merged) // 2
        check((merged.card_ids[:half] == merged.card_ids[half:]).all(),
              "identical games recorded with different id orders merge to identical ids")
        check(len(np.unique(merged.groups)) == 16, "game ids stay unique across files")

        train, val = split_by_game(merged, val_fraction=0.25, seed=0)
        overlap = set(train.groups.tolist()) & set(val.groups.tolist())
        check(not overlap, "no game appears in both the train and validation split")
        check(len(train) + len(val) == len(merged), "the split loses no samples")


def test_degenerate_dataset_warning() -> None:
    print("degenerate dataset detection")
    samples = synthetic_samples(games=30, seed=13)
    rates = samples.seat_win_rates()
    check(abs(sum(rates.values()) - 1.0) < 1e-9, "seat win rates sum to 1")
    check(max(rates.values()) < 0.95, f"balanced data is not flagged (max {max(rates.values()):.2f})")

    # One seat wins every game — what a broken agent produces.
    samples.targets = np.where(samples.players == 0, 1.0, 0.0).astype(np.float32)
    check(samples.seat_win_rates()[0] == 1.0, "a one-sided dataset reports a 100% seat win rate")
    check("WARNING" in samples.describe(), "describe() warns about a one-sided dataset")


def test_checkpoint_round_trip() -> None:
    print("checkpoints")
    samples = synthetic_samples(games=5, seed=7)
    model = ValueNet(samples.spec, ModelConfig(embed_dim=8, dropout=0.0)).eval()
    features = torch.from_numpy(samples.features[:4])
    card_ids = torch.from_numpy(samples.card_ids[:4])
    before = model(features, card_ids)

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "model.pt"
        torch.save(model.checkpoint(), path)
        restored = ValueNet.load(str(path))

    after = restored(features, card_ids)
    check(torch.allclose(before, after, atol=1e-6), "a reloaded checkpoint predicts identically")
    check(restored.spec.vocabulary == samples.spec.vocabulary, "the vocabulary survives the round trip")
    check(restored.config.embed_dim == 8, "the model config survives the round trip")


def test_metrics() -> None:
    print("metrics")
    perfect = np.array([0.9, 0.8, 0.2, 0.1])
    targets = np.array([1.0, 1.0, 0.0, 0.0])
    check(accuracy(perfect, targets) == 1.0, "accuracy 1.0 on perfect predictions")
    check(auc(perfect, targets) == 1.0, "auc 1.0 on perfectly ranked predictions")
    check(abs(auc(1 - perfect, targets)) < 1e-9, "auc 0.0 when the ranking is inverted")
    check(auc(np.full(4, 0.5), targets) == 0.5, "auc 0.5 on constant predictions (ties averaged)")
    check(abs(brier(targets, targets)) < 1e-12, "brier 0 on exact predictions")
    check(np.isnan(accuracy(perfect, np.full(4, 0.5))), "accuracy is nan when every game is a draw")


def test_learning() -> None:
    print("learning (short training run)")
    from .train import main as train_main

    with tempfile.TemporaryDirectory() as tmp:
        code = train_main([
            "--smoke-test", "--epochs", "8", "--out-dir", tmp, "--patience", "0", "--vocab-out", "",
        ])
        check(code == 0, "training completes")
        history = json.loads((Path(tmp) / "history.json").read_text())
        first, last = history[0]["train_loss"], history[-1]["train_loss"]
        check(last < first, f"training loss falls ({first:.4f} -> {last:.4f})")
        check(history[-1]["accuracy"] > 0.6,
              f"validation accuracy beats coin flipping ({history[-1]['accuracy']:.3f})")
        check((Path(tmp) / "value_net.pt").exists(), "a best checkpoint is written")


def main() -> int:
    torch.manual_seed(0)
    np.random.seed(0)
    for test in (
        test_spec,
        test_model_shapes,
        test_permutation_invariance,
        test_dataset_round_trip,
        test_degenerate_dataset_warning,
        test_checkpoint_round_trip,
        test_metrics,
        test_learning,
    ):
        test()
        print()
    print(f"all {_checks} checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())