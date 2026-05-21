// Package auth holds user identity, sessions, and OAuth integration.
// Implementation lands in M2 with Ory Kratos integration (T-CORE-020 / -021).
// This file exists so the module boundary is real today.
package auth

// Service is the placeholder façade for the auth domain. Concrete dependencies
// (Kratos client, user repository) wire in at M2.
type Service struct{}

// New constructs an empty Service. Returns a value; the M2 implementation will
// likely take a struct-of-deps and return a pointer.
func New() Service {
	return Service{}
}
