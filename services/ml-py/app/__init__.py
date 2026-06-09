"""Echo ML service — Python.

This package houses trait scoring, Portrait generation, reflection generation,
and the safety/tone classifiers. See ``docs/05_Technical_Architecture.md``
§"Trait, Portrait, and Reflection pipeline" for the design.

In M0 the package exposes only a FastAPI app with health endpoints and gRPC
service stubs that return ``Unimplemented``. Real implementations land at the
task IDs noted in each submodule.
"""

__version__ = "0.1.0"
