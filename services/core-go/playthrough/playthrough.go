// Package playthrough manages the lifecycle of a player's journey through a
// Season: start, pause, resume, record choices, finalize. Concrete handlers
// land at T-CORE-010 in M1.
package playthrough

// Service is the placeholder façade for the playthrough domain.
type Service struct{}

// New constructs an empty Service.
func New() Service {
	return Service{}
}
