from dataclasses import asdict, is_dataclass
from typing import Any


def to_jsonable(value: Any) -> Any:
    if is_dataclass(value):
        return to_jsonable(asdict(value))
    if isinstance(value, dict):
        return {str(k): to_jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [to_jsonable(v) for v in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if hasattr(value, "__dict__"):
        return {
            key: to_jsonable(val)
            for key, val in vars(value).items()
            if not key.startswith("_")
        }
    return str(value)


def attr(value: Any, name: str, default: Any = None) -> Any:
    return getattr(value, name, default)


def nested_attr(value: Any, *names: str, default: Any = None) -> Any:
    current = value
    for name in names:
        current = getattr(current, name, None)
        if current is None:
            return default
    return current
