// Package auth wires Echo to Ory Kratos.
//
// Boundaries
//
//   - Kratos owns identity, credentials, sessions, recovery, and verification.
//     We never store passwords or session tokens; Kratos does.
//   - The Go backend keeps a slim `auth.users` table (see migrations) that
//     joins on `kratos_identity_id` for the few things Echo cares about
//     beyond identity: age band, consent state, last-seen.
//   - Every request that needs to know who the user is goes through the
//     [Middleware]. Handlers downstream of the middleware call
//     [SessionFromContext] to read the typed [Session]; handlers should
//     never read the Kratos cookie directly.
//
// Safety
//
//   - Under-13 identities are rejected at sign-up by [EvaluateAgeGate]. This
//     is a hard rule from docs/08_Data_Privacy_Compliance.md §"Age gating
//     and minor protections" and cannot be coded around without human
//     review (see AGENTS.md §"What AI agents should escalate to humans").
//   - 13–17 identities are routed into the youth-safe flow via [AgeBand]
//     on the user record. Sharing is disabled and reflection generation
//     uses stricter templates; those policies live with the features they
//     constrain, not here.
package auth

// Service is the auth domain entry point used by `cmd/core` to construct
// the middleware and any future RPC handlers.
type Service struct {
	Kratos *KratosClient
}

// New constructs a [Service] from its dependencies. Returns a pointer because
// the underlying KratosClient holds a long-lived HTTP client.
func New(k *KratosClient) *Service {
	return &Service{Kratos: k}
}
