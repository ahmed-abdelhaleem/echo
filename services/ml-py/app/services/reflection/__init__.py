"""Reflection pipeline (T-ML-042).

End-to-end:

    trait vector + signal moments
      -> template selection (T-ML-040)
      -> prompt assembly
      -> LLM completion (T-ML-041)
      -> safety classifier
      -> tone classifier
      -> output

Failure at any step routes to a curated fallback string. The pipeline
never returns a raw exception to the gRPC caller; it returns a
:class:`ReflectionResult` with ``is_fallback=True`` and
``fallback_reason`` set, so post-hoc replay can see exactly why.
"""

from app.services.reflection.pipeline import (
    ClassifierScores,
    ReflectionPipeline,
    ReflectionResult,
    build_pipeline_from_env,
)
from app.services.reflection.prompt import build_prompt
from app.services.reflection.safety import (
    SafetyClassifier,
    SafetyResult,
    default_safety_classifier,
)
from app.services.reflection.tone import (
    ToneClassifier,
    ToneResult,
    default_tone_classifier,
)

__all__ = [
    "ClassifierScores",
    "ReflectionPipeline",
    "ReflectionResult",
    "SafetyClassifier",
    "SafetyResult",
    "ToneClassifier",
    "ToneResult",
    "build_pipeline_from_env",
    "build_prompt",
    "default_safety_classifier",
    "default_tone_classifier",
]
