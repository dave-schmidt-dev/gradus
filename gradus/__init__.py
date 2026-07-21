"""gradus package."""

__all__ = ["main"]


def __getattr__(name: str):
    if name == "main":
        from .__main__ import main

        return main
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
