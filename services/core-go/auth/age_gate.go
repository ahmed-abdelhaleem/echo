package auth

import (
	"errors"
	"fmt"
	"time"
)

// AgeBand is the classification Echo's downstream policies use.
//
// The two bands are mutually exclusive and exhaustive for accepted users.
// Under-13 identities are NOT represented as a band — they are rejected at
// the gate. Keeping that case out of the type makes the youth-safe path
// statically un-skippable.
type AgeBand string

const (
	// AgeBandYouth corresponds to ages 13–17 inclusive. Sharing is disabled,
	// reflection generation uses stricter templates, and extended analytics
	// are disabled (docs/08_Data_Privacy_Compliance.md).
	AgeBandYouth AgeBand = "youth"

	// AgeBandAdult corresponds to ages 18 and over.
	AgeBandAdult AgeBand = "adult"
)

// AgeGateDecision is the result of evaluating an applicant's birthdate.
type AgeGateDecision struct {
	// Allowed reports whether the applicant is allowed to sign up at all.
	Allowed bool

	// Band is set iff Allowed is true.
	Band AgeBand

	// Reason explains a denial in plain language; populated when Allowed
	// is false. We deliberately do NOT include the applicant's age in the
	// reason string so it can be surfaced to the user safely.
	Reason string
}

// ErrInvalidBirthdate is returned by [EvaluateAgeGate] when the birthdate
// string cannot be parsed as ISO `yyyy-mm-dd`.
var ErrInvalidBirthdate = errors.New("auth: invalid birthdate; expected yyyy-mm-dd")

// MinAgeYears is the absolute minimum age to be an Echo user.
//
// This constant exists so it is searchable. It is set to 13 because
// docs/08 §"Age gating and minor protections" treats under-13 as a hard
// no — anything younger requires parental-consent infrastructure that
// Echo deliberately does not build.
const MinAgeYears = 13

// AdultAgeYears is the lower bound for [AgeBandAdult].
const AdultAgeYears = 18

// EvaluateAgeGate classifies an applicant by birthdate against the policy
// in docs/08_Data_Privacy_Compliance.md. The `now` argument is taken
// explicitly so tests can pin the clock.
//
// The function never panics for an unparseable birthdate; it returns
// [ErrInvalidBirthdate] so callers can surface a 400 to the client without
// crashing the server.
func EvaluateAgeGate(birthdate string, now time.Time) (AgeGateDecision, error) {
	if birthdate == "" {
		return AgeGateDecision{}, ErrInvalidBirthdate
	}
	dob, err := time.Parse("2006-01-02", birthdate)
	if err != nil {
		return AgeGateDecision{}, fmt.Errorf("%w: %v", ErrInvalidBirthdate, err)
	}

	// Future date — refuse to interpret.
	if dob.After(now) {
		return AgeGateDecision{}, fmt.Errorf("%w: birthdate is in the future", ErrInvalidBirthdate)
	}

	age := yearsBetween(dob, now)

	switch {
	case age < MinAgeYears:
		return AgeGateDecision{
			Allowed: false,
			Reason:  "Echo is not available to users under 13.",
		}, nil
	case age < AdultAgeYears:
		return AgeGateDecision{Allowed: true, Band: AgeBandYouth}, nil
	default:
		return AgeGateDecision{Allowed: true, Band: AgeBandAdult}, nil
	}
}

// yearsBetween returns the number of full calendar years from `from` to `to`,
// using the same calendar-aware definition humans use ("turning N").
func yearsBetween(from, to time.Time) int {
	years := to.Year() - from.Year()
	// If `to`'s month/day is before `from`'s month/day this year, the
	// applicant has not yet had their birthday — subtract one.
	if to.Month() < from.Month() ||
		(to.Month() == from.Month() && to.Day() < from.Day()) {
		years--
	}
	return years
}
