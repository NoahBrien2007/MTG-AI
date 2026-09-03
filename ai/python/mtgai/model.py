"""The value network: P(the acting player wins this game).

Architecture, in one paragraph. The 1109-float state vector is really two
things glued together: 36 global numbers (life, mana, phase, counts) and 37
card slots of 29 numbers each. Feeding that flat into an MLP wastes capacity,
because slot 3 of your battlefield means the same thing as slot 7 — so instead
every slot is passed through the *same* small encoder together with a learned
embedding of its card name, and the results are pooled per zone (mean + max
over the occupied slots). That makes the model permutation-invariant inside a
zone and gives it a per-card lookup table it can use to learn what "Burst
Lightning" does. The pooled zone vectors and the global features then go
through a small trunk to a single logit.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any

import torch
from torch import Tensor, nn

from .spec import EncodingSpec


@dataclass
class ModelConfig:
    embed_dim: int = 32
    card_hidden: int = 96
    card_out: int = 64
    trunk_hidden: int = 256
    dropout: float = 0.1

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class ValueNet(nn.Module):
    """Scores a state from the acting player's point of view."""

    def __init__(self, spec: EncodingSpec, config: ModelConfig | None = None) -> None:
        super().__init__()
        self.spec = spec
        self.config = config or ModelConfig()
        self._zones = spec.zone_bounds()

        self.card_embedding = nn.Embedding(spec.vocab_size, self.config.embed_dim, padding_idx=0)

        self.card_encoder = nn.Sequential(
            nn.Linear(spec.card_features + self.config.embed_dim, self.config.card_hidden),
            nn.ReLU(),
            nn.Linear(self.config.card_hidden, self.config.card_out),
            nn.ReLU(),
        )

        # mean + max per zone
        pooled = len(self._zones) * 2 * self.config.card_out
        self.trunk = nn.Sequential(
            nn.Linear(spec.global_features + pooled, self.config.trunk_hidden),
            nn.ReLU(),
            nn.Dropout(self.config.dropout),
            nn.Linear(self.config.trunk_hidden, self.config.trunk_hidden // 2),
            nn.ReLU(),
            nn.Dropout(self.config.dropout),
        )
        self.head = nn.Linear(self.config.trunk_hidden // 2, 1)

        self.apply(self._init_weights)

    @staticmethod
    def _init_weights(module: nn.Module) -> None:
        if isinstance(module, nn.Linear):
            nn.init.kaiming_uniform_(module.weight, nonlinearity="relu")
            if module.bias is not None:
                nn.init.zeros_(module.bias)
        elif isinstance(module, nn.Embedding):
            nn.init.normal_(module.weight, std=0.05)
            with torch.no_grad():
                module.weight[module.padding_idx].zero_()

    # ------------------------------------------------------------- forward

    def forward(self, features: Tensor, card_ids: Tensor) -> Tensor:
        """Returns the win logit, shape (batch,)."""
        spec = self.spec
        globals_ = features[:, : spec.global_features]
        cards = features[:, spec.global_features :].reshape(
            features.shape[0], spec.total_slots, spec.card_features
        )

        # Feature 0 of every slot is the "a card is here" flag.
        occupied = cards[..., :1]

        encoded = self.card_encoder(torch.cat([cards, self.card_embedding(card_ids)], dim=-1))
        encoded = encoded * occupied  # empty slots contribute nothing

        pooled: list[Tensor] = []
        for _, start, end in self._zones:
            zone = encoded[:, start:end, :]
            mask = occupied[:, start:end, :]
            count = mask.sum(dim=1).clamp(min=1.0)
            pooled.append(zone.sum(dim=1) / count)
            # -inf on empty slots would poison the max, so push them very low
            pooled.append(zone.masked_fill(mask == 0, -1e4).amax(dim=1).clamp(min=0.0))

        hidden = self.trunk(torch.cat([globals_, *pooled], dim=-1))
        return self.head(hidden).squeeze(-1)

    @torch.no_grad()
    def win_probability(self, features: Tensor, card_ids: Tensor) -> Tensor:
        """Convenience wrapper: sigmoid of the logit, in [0, 1]."""
        self.eval()
        return torch.sigmoid(self(features, card_ids))

    # ---------------------------------------------------------- checkpoints

    def checkpoint(self, extra: dict[str, Any] | None = None) -> dict[str, Any]:
        return {
            "format": "mtg-ai-valuenet-v1",
            "spec": self.spec.to_dict(),
            "config": self.config.to_dict(),
            "state_dict": self.state_dict(),
            **(extra or {}),
        }

    @classmethod
    def from_checkpoint(cls, checkpoint: dict[str, Any]) -> ValueNet:
        if checkpoint.get("format") != "mtg-ai-valuenet-v1":
            raise ValueError(f"unexpected checkpoint format {checkpoint.get('format')!r}")
        model = cls(
            EncodingSpec.from_dict(checkpoint["spec"]),
            ModelConfig(**checkpoint["config"]),
        )
        model.load_state_dict(checkpoint["state_dict"])
        model.eval()
        return model

    @classmethod
    def load(cls, path: str, map_location: str = "cpu") -> ValueNet:
        return cls.from_checkpoint(torch.load(path, map_location=map_location, weights_only=False))

    def parameter_count(self) -> int:
        return sum(p.numel() for p in self.parameters())
