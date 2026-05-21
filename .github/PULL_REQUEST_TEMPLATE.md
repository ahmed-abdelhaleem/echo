## Summary

<!--
What does this PR change and why? One paragraph max. Link the task IDs from
docs/07_AI_Agent_Implementation_Guide.md that this PR closes or moves forward,
e.g. "Closes T-INFRA-001..005, T-CORE-001..005."
-->

## Acceptance criteria

<!-- Pulled from docs/07 if applicable. Tick what's covered. -->
- [ ] ...

## Touches a human-review area?

<!--
See AGENTS.md "What AI agents should escalate to humans". Tick all that apply.
If anything is ticked, add the `human-review-required` label.
-->
- [ ] New top-level dependency
- [ ] Migration that drops/renames
- [ ] Auth / session handling
- [ ] Trait scoring engine
- [ ] Safety or tone classifier
- [ ] Reflection templates (`/content/reflection-templates/`)
- [ ] Age-gating / consent / youth-safe path
- [ ] Data residency / region pinning / backup encryption
- [ ] Public API contract used by clients in the wild
- [ ] Billing logic

## Verification

- [ ] `make lint` ✔
- [ ] `make test` ✔
- [ ] `make build` ✔
- [ ] `make validate-content` ✔ (if content touched)
- [ ] `make replay` ✔ (if scoring / weights touched)

## Notes for reviewers

<!-- Anything tricky, anything you considered and rejected, anything you'd want a reviewer to look at twice. -->
