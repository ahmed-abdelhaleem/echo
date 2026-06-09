// Package org owns the B2B / Institution data model: Institution, Cohort,
// Educator, Seat, Consent. M4 scope (T-B2B-001..003). This file establishes
// the module boundary so cross-cutting refactors are visible early.
package org

// Service is the placeholder façade for the org/institution domain.
type Service struct{}

// New constructs an empty Service.
func New() Service {
	return Service{}
}
