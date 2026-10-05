from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class Signal:
    space: str
    reference: str
    range: str

    @classmethod
    def from_dict(cls, value, label):
        if not isinstance(value, dict) or set(value) != {"space", "reference", "range"}:
            raise ValueError(f"{label} requires exactly space, reference and range")
        if not isinstance(value["space"], str) or not value["space"].strip():
            raise ValueError(f"{label}.space must be explicit")
        if value["reference"] not in ("scene", "display"):
            raise ValueError(f"{label}.reference must be scene or display")
        if value["range"] not in ("full", "legal10"):
            raise ValueError(f"{label}.range must be full or legal10")
        return cls(**value)


@dataclass(frozen=True)
class Contract:
    input: Signal
    output: Signal
    interpolation: str = "linear"
    ocio: dict | None = None

    @classmethod
    def from_dict(cls, value):
        if not isinstance(value, dict):
            raise ValueError("Contract must be a JSON object")
        extra = set(value) - {"version", "input", "output", "interpolation", "ocio"}
        if extra:
            raise ValueError(f"Unknown contract fields: {', '.join(sorted(extra))}")
        if type(value.get("version")) is not int or value["version"] != 1:
            raise ValueError("Contract version must be 1")
        source = Signal.from_dict(value.get("input"), "input")
        target = Signal.from_dict(value.get("output"), "output")
        if source.reference == "display" and target.reference == "scene":
            raise ValueError("Cannot recover scene radiance with a display-to-scene contract")
        interpolation = value.get("interpolation", "linear")
        if interpolation not in ("linear", "tetrahedral"):
            raise ValueError("interpolation must be linear or tetrahedral")
        config = value.get("ocio")
        if config is not None:
            if (not isinstance(config, dict) or set(config) != {"config", "reference_space"}
                    or any(not isinstance(v, str) or not v.strip() for v in config.values())):
                raise ValueError("ocio requires config and a scene-linear-sRGB reference_space")
        return cls(source, target, interpolation, config)

    def to_dict(self):
        result = {"version": 1, "input": asdict(self.input), "output": asdict(self.output),
                  "interpolation": self.interpolation}
        if self.ocio:
            result["ocio"] = dict(self.ocio)
        return result
