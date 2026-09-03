"""Encoding layout shared by the Godot encoder and the PyTorch model.

Everything here mirrors `scripts/ai/state_encoder.gd`. The values are read from
the header line of a dataset rather than hard-coded, so a change on the Godot
side does not silently corrupt training — it either flows through or raises.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

# Fallbacks for datasets recorded before the header carried the layout.
DEFAULT_GLOBAL_FEATURES = 37
DEFAULT_CARD_FEATURES = 29
#: encode_action(): a 9-way type one-hot plus 9 values.
DEFAULT_ACTION_FEATURES = 18
DEFAULT_SLOTS = {"hand": 10, "battlefield": 12, "stack": 3}

#: Order of the zones inside the card-slot part of the feature vector.
ZONE_NAMES = ("hand", "my_battlefield", "opp_battlefield", "stack")


@dataclass
class EncodingSpec:
    """Shape of one encoded state, plus the card-name vocabulary."""

    global_features: int = DEFAULT_GLOBAL_FEATURES
    card_features: int = DEFAULT_CARD_FEATURES
    hand_slots: int = DEFAULT_SLOTS["hand"]
    battlefield_slots: int = DEFAULT_SLOTS["battlefield"]
    stack_slots: int = DEFAULT_SLOTS["stack"]
    action_features: int = DEFAULT_ACTION_FEATURES
    #: Index 0 is the empty slot / unknown card; the rest are card names.
    vocabulary: list[str] = field(default_factory=lambda: [""])

    # ---------------------------------------------------------------- shapes

    @property
    def total_slots(self) -> int:
        return self.hand_slots + 2 * self.battlefield_slots + self.stack_slots

    @property
    def feature_count(self) -> int:
        return self.global_features + self.total_slots * self.card_features

    @property
    def vocab_size(self) -> int:
        return len(self.vocabulary)

    @property
    def zone_sizes(self) -> tuple[int, int, int, int]:
        """Slot count per zone, in feature-vector order."""
        return (
            self.hand_slots,
            self.battlefield_slots,
            self.battlefield_slots,
            self.stack_slots,
        )

    def zone_bounds(self) -> list[tuple[str, int, int]]:
        """`(name, start_slot, end_slot)` for every zone."""
        bounds, start = [], 0
        for name, size in zip(ZONE_NAMES, self.zone_sizes):
            bounds.append((name, start, start + size))
            start += size
        return bounds

    # ------------------------------------------------------------ vocabulary

    def card_id(self, card_name: str) -> int:
        """Index of a card name, 0 when unknown."""
        try:
            return self.vocabulary.index(card_name)
        except ValueError:
            return 0

    def merge_vocabulary(self, names: list[str]) -> dict[int, int]:
        """Adds `names` to this vocabulary.

        Returns a remap table from the *incoming* id to this spec's id, because
        two recording sessions can assign different ids to the same card.
        """
        index = {name: i for i, name in enumerate(self.vocabulary)}
        remap: dict[int, int] = {}
        for incoming_id, name in enumerate(names):
            if not name:
                remap[incoming_id] = 0
                continue
            if name not in index:
                index[name] = len(self.vocabulary)
                self.vocabulary.append(name)
            remap[incoming_id] = index[name]
        return remap

    # ------------------------------------------------------- serialisation

    @classmethod
    def from_header(cls, header: dict[str, Any]) -> EncodingSpec:
        slots = header.get("slots") or DEFAULT_SLOTS
        spec = cls(
            global_features=int(header.get("global_features", DEFAULT_GLOBAL_FEATURES)),
            card_features=int(header.get("card_features", DEFAULT_CARD_FEATURES)),
            hand_slots=int(slots.get("hand", DEFAULT_SLOTS["hand"])),
            battlefield_slots=int(slots.get("battlefield", DEFAULT_SLOTS["battlefield"])),
            stack_slots=int(slots.get("stack", DEFAULT_SLOTS["stack"])),
            action_features=int(header.get("action_features", 18)),
            vocabulary=[""],
        )
        spec.merge_vocabulary(list(header.get("vocabulary", [])))

        declared = header.get("feature_count")
        if declared is not None and int(declared) != spec.feature_count:
            raise ValueError(
                f"dataset says feature_count={declared} but its layout implies "
                f"{spec.feature_count}; the Godot encoder and this file disagree"
            )
        return spec

    def to_dict(self) -> dict[str, Any]:
        return {
            "global_features": self.global_features,
            "card_features": self.card_features,
            "slots": {
                "hand": self.hand_slots,
                "battlefield": self.battlefield_slots,
                "stack": self.stack_slots,
            },
            "action_features": self.action_features,
            "feature_count": self.feature_count,
            "vocabulary": self.vocabulary,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> EncodingSpec:
        return cls.from_header(data)

    def compatible_with(self, other: EncodingSpec) -> bool:
        """True when two specs have the same tensor shapes (vocabulary aside)."""
        return (
            self.global_features == other.global_features
            and self.card_features == other.card_features
            and self.zone_sizes == other.zone_sizes
        )