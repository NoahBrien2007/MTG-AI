"""The policy network: which move does a strong player make here?

Why this sits next to the value network. Outcome training gives one label per
*game*, shared by all ~300 decisions in it — roughly 2,000 real signals inside
650,000 rows, which is why the value net stopped improving after one or two
epochs however it was regularised, and why using it to pick moves lost badly.
`chosen` gives one label per *decision*, discriminated against the ~25 other
legal actions of that same position: the same files on disk, three hundred
times the supervision, and aimed directly at the thing that chooses moves.

    python -m mtgai.policy --smoke-test    # synthetic data, checks the loop
    python -m mtgai.policy                 # trains on ../training/datasets
    python -m mtgai.serve --policy-checkpoint checkpoints/policy_net.pt

The number to watch is top-1 agreement: the fraction of held-out positions
where the network would have played the same move as the agent that recorded
them. Chance is roughly 1/(legal actions), about 4%. Agreement in the 80s means
it has learned to play; the ceiling is the strength of whoever recorded.
"""

from __future__ import annotations

import argparse
import json
import random
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

import numpy as np
import torch
from torch import Tensor, nn
from torch.utils.data import DataLoader, Dataset

from .data import find_datasets, _read_lines
from .model import ModelConfig, ValueNet
from .paths import CHECKPOINT_DIR, DATASET_DIR, VOCABULARY_PATH
from .spec import EncodingSpec


# --------------------------------------------------------------------- model

@dataclass
class PolicyConfig:
    """Body sized like the value net that won the sweep, plus an action head."""

    embed_dim: int = 16
    card_hidden: int = 64
    card_out: int = 32
    trunk_hidden: int = 128
    dropout: float = 0.2
    action_hidden: int = 64

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class PolicyNet(nn.Module):
    """Scores every legal action of a position; a softmax picks the move.

    The board is read by the same body as `ValueNet` — pooled card slots, shared
    card encoder, permutation-invariant inside a zone. Each candidate action is
    then scored by concatenating its 19-float description onto that one state
    vector, so the state is encoded once per decision rather than once per
    action, and actions compete inside a single softmax.
    """

    def __init__(self, spec: EncodingSpec, config: PolicyConfig | None = None) -> None:
        super().__init__()
        self.spec = spec
        self.config = config or PolicyConfig()
        self.body = ValueNet(spec, ModelConfig(
            embed_dim=self.config.embed_dim,
            card_hidden=self.config.card_hidden,
            card_out=self.config.card_out,
            trunk_hidden=self.config.trunk_hidden,
            dropout=self.config.dropout,
        ))
        state_dim = self.config.trunk_hidden // 2
        self.scorer = nn.Sequential(
            nn.Linear(state_dim + spec.action_features, self.config.action_hidden),
            nn.ReLU(),
            nn.Dropout(self.config.dropout),
            nn.Linear(self.config.action_hidden, 1),
        )

    def forward(self, features: Tensor, card_ids: Tensor, actions: Tensor, mask: Tensor) -> Tensor:
        """Logits per action slot, shape (batch, actions). Padding is masked out."""
        hidden = self.body.state_embedding(features, card_ids)
        batch, slots, _ = actions.shape
        spread = hidden.unsqueeze(1).expand(batch, slots, hidden.shape[-1])
        logits = self.scorer(torch.cat([spread, actions], dim=-1)).squeeze(-1)
        # -1e9 rather than -inf: a row that somehow has no legal action still
        # produces a finite loss instead of a NaN that poisons the whole batch.
        return logits.masked_fill(~mask, -1e9)

    # ---------------------------------------------------------- checkpoints

    def checkpoint(self, extra: dict[str, Any] | None = None) -> dict[str, Any]:
        return {
            "format": "mtg-ai-policynet-v1",
            "spec": self.spec.to_dict(),
            "config": self.config.to_dict(),
            "state_dict": self.state_dict(),
            **(extra or {}),
        }

    @classmethod
    def from_checkpoint(cls, checkpoint: dict[str, Any]) -> PolicyNet:
        if checkpoint.get("format") != "mtg-ai-policynet-v1":
            raise ValueError(f"unexpected checkpoint format {checkpoint.get('format')!r}")
        model = cls(EncodingSpec.from_dict(checkpoint["spec"]), PolicyConfig(**checkpoint["config"]))
        model.load_state_dict(checkpoint["state_dict"])
        model.eval()
        return model

    @classmethod
    def load(cls, path: str, map_location: str = "cpu") -> PolicyNet:
        return cls.from_checkpoint(torch.load(path, map_location=map_location, weights_only=False))

    def parameter_count(self) -> int:
        return sum(p.numel() for p in self.parameters())


# ---------------------------------------------------------------------- data

@dataclass
class PolicySamples:
    features: np.ndarray     # (N, feature_count) float32
    card_ids: np.ndarray     # (N, total_slots)   int64
    actions: np.ndarray      # (N, A, action_features) float32
    mask: np.ndarray         # (N, A) bool — which slots are real actions
    chosen: np.ndarray       # (N,) int64
    groups: np.ndarray       # (N,) int32 — game id, unique across files
    spec: EncodingSpec

    def __len__(self) -> int:
        return int(self.features.shape[0])

    def subset(self, indices: np.ndarray) -> PolicySamples:
        idx = np.asarray(indices, dtype=np.int64)
        return PolicySamples(
            self.features[idx], self.card_ids[idx], self.actions[idx],
            self.mask[idx], self.chosen[idx], self.groups[idx], self.spec,
        )

    def describe(self) -> str:
        counts = self.mask.sum(axis=1)
        chance = float(np.mean(1.0 / np.maximum(counts, 1)))
        return (
            f"{len(self)} decisions from {len(np.unique(self.groups))} games, "
            f"{counts.mean():.1f} legal actions each (max {self.actions.shape[1]})\n"
            f"picking at random would agree {chance:.1%} of the time"
        )


def load_policy_samples(
    paths: Iterable[str | Path],
    max_per_game: int = 60,
    max_actions: int = 48,
    seed: int = 0,
    verbose: bool = True,
) -> PolicySamples:
    """Loads decisions and their legal-action lists.

    `max_per_game` matters: 2,000 games is ~650,000 decisions, and holding every
    one of those with its padded action matrix needs several GB. Decisions
    inside one game are also highly correlated, so a sample of each game costs
    far less information than it saves memory. Sampling is reservoir-style, so
    it is spread across the whole game rather than taken from the opening.
    """
    files = find_datasets(paths)
    rng = random.Random(seed)

    spec: EncodingSpec | None = None
    feature_rows: list[np.ndarray] = []
    id_rows: list[np.ndarray] = []
    action_rows: list[np.ndarray] = []
    chosen: list[int] = []
    groups: list[int] = []
    next_group = 0
    skipped_wide = 0
    skipped_trivial = 0

    def flush(reservoir: list[dict], remap: dict[int, int], group: int) -> None:
        for sample in reservoir:
            feature_rows.append(np.asarray(sample["features"], dtype=np.float32))
            ids = np.asarray(sample["card_ids"], dtype=np.int64)
            id_rows.append(np.array([remap.get(int(i), 0) for i in ids], dtype=np.int64))
            action_rows.append(np.asarray(sample["legal"], dtype=np.float32))
            chosen.append(int(sample["chosen"]))
            groups.append(group)

    for path in files:
        lines = _read_lines(path)
        try:
            header = next(lines)
        except StopIteration:
            continue
        if header.get("format") != "mtg-ai-samples-v1":
            raise ValueError(f"{path}: unexpected format {header.get('format')!r}")

        file_spec = EncodingSpec.from_header(header)
        if spec is None:
            spec = file_spec
            remap = {i: i for i in range(file_spec.vocab_size)}
        else:
            if not spec.compatible_with(file_spec):
                raise ValueError(
                    f"{path}: encoding layout differs from earlier files — "
                    "retrain from a single generation of recordings"
                )
            remap = spec.merge_vocabulary(file_spec.vocabulary)

        seen_games: dict[int, int] = {}
        reservoir: list[dict] = []
        current_local = None
        current_group = -1
        seen_in_game = 0
        kept = 0

        for sample in lines:
            legal = sample.get("legal") or []
            # One legal action is not a decision, and a position with more
            # options than the padding allows would distort the softmax.
            if len(legal) < 2:
                skipped_trivial += 1
                continue
            if len(legal) > max_actions:
                skipped_wide += 1
                continue
            if len(legal[0]) != spec.action_features:
                raise ValueError(
                    f"{path}: action vectors are {len(legal[0])} long, "
                    f"expected {spec.action_features}"
                )

            local = int(sample.get("game", 0))
            if local != current_local:
                if current_local is not None:
                    flush(reservoir, remap, current_group)
                    kept += len(reservoir)
                reservoir = []
                seen_in_game = 0
                current_local = local
                if local not in seen_games:
                    seen_games[local] = next_group
                    next_group += 1
                current_group = seen_games[local]

            seen_in_game += 1
            if len(reservoir) < max_per_game:
                reservoir.append(sample)
            else:
                # Reservoir sampling: every decision of the game has the same
                # chance of being kept, so the sample is not all opening moves.
                j = rng.randrange(seen_in_game)
                if j < max_per_game:
                    reservoir[j] = sample

        if current_local is not None:
            flush(reservoir, remap, current_group)
            kept += len(reservoir)
        if verbose:
            print(f"  {path.name}: {kept} decisions kept from {len(seen_games)} games")

    if spec is None or not feature_rows:
        raise ValueError("datasets contained no usable decisions")

    width = max(row.shape[0] for row in action_rows)
    count = len(action_rows)
    actions = np.zeros((count, width, spec.action_features), dtype=np.float32)
    mask = np.zeros((count, width), dtype=bool)
    for i, row in enumerate(action_rows):
        actions[i, : row.shape[0]] = row
        mask[i, : row.shape[0]] = True
    action_rows.clear()

    if verbose and (skipped_wide or skipped_trivial):
        print(f"  skipped {skipped_trivial} forced moves and {skipped_wide} positions "
              f"with more than {max_actions} options")

    return PolicySamples(
        features=np.stack(feature_rows),
        card_ids=np.stack(id_rows),
        actions=actions,
        mask=mask,
        chosen=np.asarray(chosen, dtype=np.int64),
        groups=np.asarray(groups, dtype=np.int32),
        spec=spec,
    )


class PolicyDataset(Dataset):
    def __init__(self, samples: PolicySamples) -> None:
        self.features = torch.from_numpy(samples.features)
        self.card_ids = torch.from_numpy(samples.card_ids)
        self.actions = torch.from_numpy(samples.actions)
        self.mask = torch.from_numpy(samples.mask)
        self.chosen = torch.from_numpy(samples.chosen)

    def __len__(self) -> int:
        return self.features.shape[0]

    def __getitem__(self, index: int) -> dict[str, Tensor]:
        return {
            "features": self.features[index],
            "card_ids": self.card_ids[index],
            "actions": self.actions[index],
            "mask": self.mask[index],
            "chosen": self.chosen[index],
        }


def split_by_game(samples: PolicySamples, val_fraction: float, seed: int) -> tuple[PolicySamples, PolicySamples]:
    """Whole games on one side or the other — decisions in a game are near
    duplicates, and splitting them across the boundary flatters the model."""
    games = np.unique(samples.groups)
    rng = np.random.default_rng(seed)
    rng.shuffle(games)
    n_val = max(1, int(round(len(games) * val_fraction))) if len(games) > 1 else 0
    val_games = set(games[:n_val].tolist())
    is_val = np.array([g in val_games for g in samples.groups])
    return samples.subset(np.flatnonzero(~is_val)), samples.subset(np.flatnonzero(is_val))


# ------------------------------------------------------------------ training

def run_epoch(model, loader, device, optimizer=None) -> tuple[float, float, float]:
    """Returns (loss, top-1 agreement, top-3 agreement)."""
    training = optimizer is not None
    model.train(training)
    loss_fn = nn.CrossEntropyLoss()
    total = correct = top3 = count = 0.0

    with torch.set_grad_enabled(training):
        for batch in loader:
            features = batch["features"].to(device)
            card_ids = batch["card_ids"].to(device)
            actions = batch["actions"].to(device)
            mask = batch["mask"].to(device)
            chosen = batch["chosen"].to(device)

            logits = model(features, card_ids, actions, mask)
            loss = loss_fn(logits, chosen)

            if training:
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                nn.utils.clip_grad_norm_(model.parameters(), 5.0)
                optimizer.step()

            n = chosen.shape[0]
            total += float(loss.detach()) * n
            correct += float((logits.argmax(dim=-1) == chosen).sum())
            ranked = logits.topk(min(3, logits.shape[-1]), dim=-1).indices
            top3 += float((ranked == chosen.unsqueeze(-1)).any(dim=-1).sum())
            count += n

    count = max(count, 1.0)
    return total / count, correct / count, top3 / count


def synthetic_policy_samples(decisions: int = 4000, options: int = 12, seed: int = 0) -> PolicySamples:
    """A learnable toy task, to check the training loop without recordings.

    The right action is always the one whose first feature is largest, so a
    working setup should reach near-perfect agreement in a few epochs. If this
    plateaus near chance, the bug is in the code, not in your data.
    """
    # A few real vocabulary entries, so the card embedding is exercised rather
    # than indexed out of a one-row table.
    spec = EncodingSpec(vocabulary=["", "Island", "Opt", "Burst Lightning"])
    rng = np.random.default_rng(seed)
    features = rng.random((decisions, spec.feature_count), dtype=np.float32)
    card_ids = rng.integers(0, spec.vocab_size, size=(decisions, spec.total_slots)).astype(np.int64)
    actions = rng.random((decisions, options, spec.action_features), dtype=np.float32)
    mask = np.ones((decisions, options), dtype=bool)
    chosen = actions[:, :, 0].argmax(axis=1).astype(np.int64)
    groups = (np.arange(decisions) // 20).astype(np.int32)
    return PolicySamples(features, card_ids, actions, mask, chosen, groups, spec)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("datasets", nargs="*", default=[str(DATASET_DIR)])
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--dropout", type=float, default=PolicyConfig.dropout)
    parser.add_argument("--val-fraction", type=float, default=0.15)
    parser.add_argument("--patience", type=int, default=6)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--max-per-game", type=int, default=60,
                        help="decisions sampled per game; the whole dataset needs several GB")
    parser.add_argument("--max-actions", type=int, default=48)
    parser.add_argument("--out-dir", default=str(CHECKPOINT_DIR))
    parser.add_argument("--vocab-out", default=str(VOCABULARY_PATH))
    parser.add_argument("--smoke-test", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    if args.smoke_test:
        print("Smoke test: synthetic decisions, the answer is always action feature 0")
        samples = synthetic_policy_samples(seed=args.seed)
    else:
        print(f"Loading datasets from {', '.join(str(p) for p in args.datasets)}")
        try:
            samples = load_policy_samples(
                args.datasets, max_per_game=args.max_per_game, max_actions=args.max_actions,
                seed=args.seed,
            )
        except FileNotFoundError as error:
            print(f"\n{error}\n")
            print("Record some games first: AI Training, tick Record training data, Run.")
            return 1

    print(samples.describe())

    # A card id past the end of the vocabulary is an opaque IndexError from
    # inside the embedding otherwise — worth naming here instead.
    highest = int(samples.card_ids.max(initial=0))
    if highest >= samples.spec.vocab_size:
        raise ValueError(
            f"card id {highest} outside the {samples.spec.vocab_size}-card vocabulary — "
            "the datasets and the encoder disagree"
        )

    train, val = split_by_game(samples, args.val_fraction, args.seed)
    print(f"split: {len(train)} train / {len(val)} validation decisions (whole games kept together)")

    device = torch.device(args.device)
    model = PolicyNet(samples.spec, PolicyConfig(dropout=args.dropout)).to(device)
    print(f"model: {model.parameter_count():,} parameters on {device}")

    train_loader = DataLoader(PolicyDataset(train), batch_size=args.batch_size, shuffle=True)
    val_loader = DataLoader(PolicyDataset(val), batch_size=args.batch_size) if len(val) else None
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(optimizer, factor=0.5, patience=2)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    best_path = out_dir / "policy_net.pt"
    best_loss, best_epoch, history = float("inf"), -1, []
    started = time.time()

    for epoch in range(1, args.epochs + 1):
        train_loss, train_top1, _ = run_epoch(model, train_loader, device, optimizer)
        if val_loader:
            val_loss, val_top1, val_top3 = run_epoch(model, val_loader, device)
        else:
            val_loss, val_top1, val_top3 = train_loss, train_top1, 0.0
        scheduler.step(val_loss)

        line = (f"epoch {epoch:3d}/{args.epochs}  train {train_loss:.4f} ({train_top1:.1%})  "
                f"val {val_loss:.4f}  agree {val_top1:.1%}  top3 {val_top3:.1%}")
        history.append({"epoch": epoch, "train_loss": train_loss, "val_loss": val_loss,
                        "agreement": val_top1, "top3": val_top3})
        if val_loss < best_loss - 1e-5:
            best_loss, best_epoch = val_loss, epoch
            torch.save(model.checkpoint({"epoch": epoch, "val_loss": val_loss, "agreement": val_top1}), best_path)
            line += "  *"
        print(line)

        if args.patience and epoch - best_epoch >= args.patience:
            print(f"no improvement for {args.patience} epochs — stopping early")
            break

    (out_dir / "policy_history.json").write_text(json.dumps(history, indent=1), encoding="utf-8")
    if not args.smoke_test and args.vocab_out:
        vocab_path = Path(args.vocab_out)
        vocab_path.parent.mkdir(parents=True, exist_ok=True)
        vocab_path.write_text(
            json.dumps({"vocabulary": samples.spec.vocabulary}, indent=1, ensure_ascii=False),
            encoding="utf-8",
        )

    best = max(history, key=lambda h: h["agreement"]) if history else {"agreement": 0.0}
    print(f"\ntrained in {time.time() - started:.1f}s; best val loss {best_loss:.4f} at epoch {best_epoch}")
    print(f"  best agreement with the recorded agent: {best['agreement']:.1%}")
    print(f"  checkpoint  {best_path}")
    print("\nServe it with:")
    print(f"  python -m mtgai.serve --policy-checkpoint {best_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
