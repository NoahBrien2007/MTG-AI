"""Evaluation metrics that say something useful about a value network."""

from __future__ import annotations

import numpy as np


def accuracy(probabilities: np.ndarray, targets: np.ndarray) -> float:
    """Fraction of decided games (draws excluded) called correctly."""
    decided = targets != 0.5
    if not decided.any():
        return float("nan")
    predicted = probabilities[decided] >= 0.5
    return float((predicted == (targets[decided] == 1.0)).mean())


def auc(probabilities: np.ndarray, targets: np.ndarray) -> float:
    """ROC AUC via rank statistics (no scikit-learn dependency)."""
    decided = targets != 0.5
    scores, labels = probabilities[decided], targets[decided] == 1.0
    positives, negatives = int(labels.sum()), int((~labels).sum())
    if positives == 0 or negatives == 0:
        return float("nan")

    order = np.argsort(scores, kind="mergesort")
    ranks = np.empty(len(scores), dtype=np.float64)
    ranks[order] = np.arange(1, len(scores) + 1)

    # Average the ranks of tied scores, otherwise ties bias the result.
    sorted_scores = scores[order]
    start = 0
    for end in range(1, len(sorted_scores) + 1):
        if end == len(sorted_scores) or sorted_scores[end] != sorted_scores[start]:
            if end - start > 1:
                ranks[order[start:end]] = ranks[order[start:end]].mean()
            start = end

    return float((ranks[labels].sum() - positives * (positives + 1) / 2) / (positives * negatives))


def brier(probabilities: np.ndarray, targets: np.ndarray) -> float:
    """Mean squared error of the probabilities — lower is better calibrated."""
    return float(np.mean((probabilities - targets) ** 2))


def calibration_table(
    probabilities: np.ndarray, targets: np.ndarray, bins: int = 10
) -> list[tuple[float, float, float, int]]:
    """`(bin_low, mean_prediction, actual_win_rate, count)` per confidence bin."""
    rows = []
    edges = np.linspace(0.0, 1.0, bins + 1)
    for low, high in zip(edges[:-1], edges[1:]):
        in_bin = (probabilities >= low) & (probabilities < high if high < 1.0 else probabilities <= 1.0)
        count = int(in_bin.sum())
        if count == 0:
            continue
        rows.append((float(low), float(probabilities[in_bin].mean()), float(targets[in_bin].mean()), count))
    return rows


def accuracy_by_turn(
    probabilities: np.ndarray, targets: np.ndarray, turns: np.ndarray, buckets: int = 5
) -> list[tuple[str, float, int]]:
    """Accuracy split by game stage — should rise as the game goes on."""
    if len(turns) == 0:
        return []
    edges = np.unique(np.quantile(turns, np.linspace(0, 1, buckets + 1)).astype(int))
    rows = []
    for low, high in zip(edges[:-1], edges[1:]):
        in_bucket = (turns >= low) & (turns < high if high < edges[-1] else turns <= high)
        count = int(in_bucket.sum())
        if count == 0:
            continue
        rows.append((
            f"turn {int(low)}-{int(high)}",
            accuracy(probabilities[in_bucket], targets[in_bucket]),
            count,
        ))
    return rows


def summary(probabilities: np.ndarray, targets: np.ndarray) -> dict[str, float]:
    return {
        "accuracy": accuracy(probabilities, targets),
        "auc": auc(probabilities, targets),
        "brier": brier(probabilities, targets),
        "mean_prediction": float(probabilities.mean()),
    }


def format_report(
    probabilities: np.ndarray, targets: np.ndarray, turns: np.ndarray | None = None
) -> str:
    stats = summary(probabilities, targets)
    lines = [
        "accuracy {accuracy:.3f}   auc {auc:.3f}   brier {brier:.4f}   "
        "mean prediction {mean_prediction:.3f}".format(**stats),
        "",
        "calibration      predicted → actual (count)",
    ]
    for low, predicted, actual, count in calibration_table(probabilities, targets):
        lines.append(f"  {low:.1f}-{low + 0.1:.1f}        {predicted:.3f} → {actual:.3f}  ({count})")

    if turns is not None and len(turns):
        lines += ["", "accuracy by game stage"]
        for label, value, count in accuracy_by_turn(probabilities, targets, turns):
            lines.append(f"  {label:<14} {value:.3f}  ({count})")
    return "\n".join(lines)
