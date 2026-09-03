"""Train the value network.

    python -m mtgai.train                          # everything in ../training/datasets
    python -m mtgai.train --epochs 60 --batch-size 512
    python -m mtgai.train --smoke-test             # synthetic data, no Godot needed

Writes `checkpoints/value_net.pt` (best validation loss) and
`checkpoints/value_net_last.pt`, plus `../training/vocabulary.json` so the
Godot encoder assigns the same card ids the model was trained with.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn

from . import metrics
from .data import Samples, load_samples, make_loaders, split_by_game
from .model import ModelConfig, ValueNet
from .paths import CHECKPOINT_DIR, DATASET_DIR, VOCABULARY_PATH


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("datasets", nargs="*", default=[str(DATASET_DIR)],
                        help="dataset files, directories or globs (default: ../training/datasets)")
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--val-fraction", type=float, default=0.15)
    parser.add_argument("--patience", type=int, default=8, help="stop after N epochs without improvement")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--workers", type=int, default=0)
    parser.add_argument("--device", default="auto", choices=["auto", "cpu", "cuda"])
    parser.add_argument("--out-dir", default=str(CHECKPOINT_DIR))
    parser.add_argument("--vocab-out", default=str(VOCABULARY_PATH),
                        help="where to write the card vocabulary Godot reads (empty string = skip)")
    parser.add_argument("--embed-dim", type=int, default=ModelConfig.embed_dim)
    parser.add_argument("--card-hidden", type=int, default=ModelConfig.card_hidden)
    parser.add_argument("--card-out", type=int, default=ModelConfig.card_out)
    parser.add_argument("--trunk-hidden", type=int, default=ModelConfig.trunk_hidden)
    parser.add_argument("--dropout", type=float, default=ModelConfig.dropout)
    parser.add_argument("--smoke-test", action="store_true",
                        help="train on synthetic data to check the pipeline end to end")
    return parser.parse_args(argv)


def pick_device(choice: str) -> torch.device:
    if choice == "auto":
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")
    return torch.device(choice)


@torch.no_grad()
def predict(model: ValueNet, samples: Samples, device: torch.device, batch: int = 1024) -> np.ndarray:
    """Win probability per sample. Cards the model never saw map to id 0."""
    model.eval()
    vocab_size = model.spec.vocab_size
    out = []
    for start in range(0, len(samples), batch):
        stop = start + batch
        ids = samples.card_ids[start:stop]
        if ids.max(initial=0) >= vocab_size:
            ids = np.where(ids >= vocab_size, 0, ids)
        features = torch.from_numpy(samples.features[start:stop]).to(device)
        card_ids = torch.from_numpy(np.ascontiguousarray(ids)).to(device)
        out.append(torch.sigmoid(model(features, card_ids)).cpu().numpy())
    return np.concatenate(out) if out else np.empty(0, dtype=np.float32)


def run_epoch(
    model: ValueNet,
    loader,
    loss_fn: nn.Module,
    device: torch.device,
    optimizer: torch.optim.Optimizer | None = None,
) -> float:
    training = optimizer is not None
    model.train(training)
    total, count = 0.0, 0

    with torch.set_grad_enabled(training):
        for batch in loader:
            features = batch["features"].to(device)
            card_ids = batch["card_ids"].to(device)
            targets = batch["target"].to(device)

            logits = model(features, card_ids)
            loss = loss_fn(logits, targets)

            if training:
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                nn.utils.clip_grad_norm_(model.parameters(), 5.0)
                optimizer.step()

            total += float(loss.detach()) * targets.shape[0]
            count += targets.shape[0]

    return total / max(count, 1)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    if args.smoke_test:
        from .testdata import synthetic_samples

        print("Smoke test: generating synthetic data instead of loading recordings")
        samples = synthetic_samples(games=120, seed=args.seed)
    else:
        print(f"Loading datasets from {', '.join(str(p) for p in args.datasets)}")
        try:
            samples = load_samples(args.datasets)
        except FileNotFoundError as error:
            print(f"\n{error}\n")
            print("Record some games first: run the game, open AI Training, tick")
            print('"Record training data" and press Run.')
            return 1

    print(samples.describe())

    train, val = split_by_game(samples, args.val_fraction, args.seed)
    print(f"split: {len(train)} train / {len(val)} validation decisions (whole games kept together)")
    if len(val) == 0:
        print("warning: not enough games for a validation split — metrics will be training-set only")

    device = pick_device(args.device)
    model = ValueNet(
        samples.spec,
        ModelConfig(
            embed_dim=args.embed_dim,
            card_hidden=args.card_hidden,
            card_out=args.card_out,
            trunk_hidden=args.trunk_hidden,
            dropout=args.dropout,
        ),
    ).to(device)
    print(f"model: {model.parameter_count():,} parameters on {device}")

    train_loader, val_loader = make_loaders(train, val, args.batch_size, args.workers)
    loss_fn = nn.BCEWithLogitsLoss()
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(optimizer, factor=0.5, patience=3)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    best_path = out_dir / "value_net.pt"
    last_path = out_dir / "value_net_last.pt"

    best_loss, best_epoch, history = float("inf"), -1, []
    started = time.time()

    for epoch in range(1, args.epochs + 1):
        train_loss = run_epoch(model, train_loader, loss_fn, device, optimizer)
        val_loss = run_epoch(model, val_loader, loss_fn, device) if val_loader else train_loss
        scheduler.step(val_loss)

        line = f"epoch {epoch:3d}/{args.epochs}  train {train_loss:.4f}  val {val_loss:.4f}"
        if len(val) > 0:
            stats = metrics.summary(predict(model, val, device), val.targets)
            line += f"  acc {stats['accuracy']:.3f}  auc {stats['auc']:.3f}"
            history.append({"epoch": epoch, "train_loss": train_loss, "val_loss": val_loss, **stats})
        else:
            history.append({"epoch": epoch, "train_loss": train_loss, "val_loss": val_loss})

        if val_loss < best_loss - 1e-5:
            best_loss, best_epoch = val_loss, epoch
            torch.save(model.checkpoint({"epoch": epoch, "val_loss": val_loss}), best_path)
            line += "  *"
        print(line)

        if args.patience and epoch - best_epoch >= args.patience:
            print(f"no improvement for {args.patience} epochs — stopping early")
            break

    torch.save(model.checkpoint({"epoch": len(history), "val_loss": best_loss}), last_path)
    (out_dir / "history.json").write_text(json.dumps(history, indent=1), encoding="utf-8")

    # The Godot encoder reads this so card ids match the embedding table.
    vocab_path = Path(args.vocab_out) if args.vocab_out else None
    if vocab_path:
        vocab_path.parent.mkdir(parents=True, exist_ok=True)
        vocab_path.write_text(
            json.dumps({"vocabulary": samples.spec.vocabulary}, indent=1, ensure_ascii=False),
            encoding="utf-8",
        )

    print(f"\ntrained in {time.time() - started:.1f}s; best val loss {best_loss:.4f} at epoch {best_epoch}")
    print(f"  best checkpoint  {best_path}")
    print(f"  last checkpoint  {last_path}")
    if vocab_path:
        print(f"  vocabulary       {vocab_path}")

    if len(val) > 0:
        best = ValueNet.load(str(best_path)).to(device)
        print("\nvalidation report (best checkpoint)")
        print(metrics.format_report(predict(best, val, device), val.targets, val.turns))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
