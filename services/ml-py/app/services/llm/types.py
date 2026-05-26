"""Public types for the LLM client abstraction."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

Role = Literal["system", "user", "assistant"]


@dataclass(frozen=True, slots=True)
class Message:
    """One chat-style message. Providers map this onto their native shape.

    Anthropic accepts ``system`` separately from ``messages`` so the
    Anthropic client extracts ``system`` from the list at request time.
    OpenAI accepts ``system`` inline so its client passes the messages
    through unchanged. Both behaviours are an implementation detail of
    the provider client and not visible to callers.
    """

    role: Role
    content: str


@dataclass(frozen=True, slots=True)
class CompletionRequest:
    """A single completion request.

    Fields:
        messages: Ordered list of role-tagged messages. Must contain at
            least one ``user`` message.
        max_output_tokens: Cap on the response length. The pipeline uses
            ~250 tokens (a 3-5 sentence reflection plus a small headroom).
        temperature: Sampling temperature in ``[0.0, 2.0]``. The pipeline
            uses 0.7 to keep reflections recognisably Echo-voiced but not
            mechanical.
        stop_sequences: Optional stop tokens. The pipeline uses
            ``["\\n\\n\\n"]`` to prevent the model from running on past the
            reflection block.
        metadata: Free-form telemetry (template_id, playthrough_id,
            request_id). Providers MAY forward this to their telemetry
            APIs; ``MockLLMClient`` echoes it back via :class:`Completion`.
    """

    messages: tuple[Message, ...]
    max_output_tokens: int = 250
    temperature: float = 0.7
    stop_sequences: tuple[str, ...] = ()
    metadata: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.messages:
            raise ValueError("messages cannot be empty")
        if not any(m.role == "user" for m in self.messages):
            raise ValueError("at least one message must have role='user'")
        if self.max_output_tokens <= 0:
            raise ValueError("max_output_tokens must be positive")
        if not 0.0 <= self.temperature <= 2.0:
            raise ValueError(
                f"temperature must be in [0.0, 2.0], got {self.temperature}",
            )


@dataclass(frozen=True, slots=True)
class Completion:
    """One completion response.

    Fields:
        text: The generated text.
        provider: Identifier of the provider that served this completion
            ("anthropic", "openai", "mock", ...). Recorded by the
            reflection pipeline's audit log so post-hoc replay can route
            to the same provider.
        model: Provider-specific model id (e.g. "claude-3-5-sonnet-20241022").
        finish_reason: Why generation stopped. Providers normalise to a
            small set: "stop" (model produced a stop sequence), "length"
            (hit max_output_tokens), "content_filter" (provider safety
            tripped). The reflection pipeline treats "content_filter" as
            a routable failure and tries the fallback.
        input_tokens / output_tokens: Optional usage counters when the
            provider reports them. Used by the cost telemetry.
        metadata: Echoed-back metadata from the request, plus any
            provider-supplied fields (request_id, etc.).
    """

    text: str
    provider: str
    model: str
    finish_reason: Literal["stop", "length", "content_filter", "unknown"]
    input_tokens: int | None = None
    output_tokens: int | None = None
    metadata: dict[str, str] = field(default_factory=dict)
