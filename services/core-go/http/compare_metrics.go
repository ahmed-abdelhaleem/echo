package http

import (
	"context"
	"sync"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
)

// compareMeterName is the OpenTelemetry meter scope for Friend Comparison
// lifecycle metrics. It mirrors the package import path so dashboards can
// attribute the counters to this package.
const compareMeterName = "github.com/ahmed-abdelhaleem/echo/services/core-go/http"

// Counter keys for the Friend Comparison lifecycle metrics from the
// implementation plan's Observability section.
const (
	metricInvitesCreated          = "invites_created"
	metricInvitesAccepted         = "invites_accepted"
	metricShareEnabled            = "share_enabled"
	metricRevoked                 = "revoked"
	metricTokenResolutionFailures = "token_resolution_failures"
)

// tokenResolvingActions are the lifecycle actions that resolve a comparison
// token; only their not_found/expired outcomes count as token-resolution
// failures (compare_invite_create's "not_found" is a playthrough miss, not a
// token miss, so it is intentionally excluded).
var tokenResolvingActions = map[string]struct{}{
	"compare_accept":       {},
	"compare_get":          {},
	"compare_portrait_get": {},
	"compare_revoke":       {},
}

// compareMetricKeys returns the counter keys an (action, outcome) lifecycle
// event increments. It is a pure function so the mapping — the part with real
// logic — is table-testable without the OpenTelemetry metric SDK.
func compareMetricKeys(action, outcome string) []string {
	var keys []string
	if outcome == "success" {
		switch action {
		case "compare_invite_create":
			keys = append(keys, metricInvitesCreated)
		case "compare_accept":
			keys = append(keys, metricInvitesAccepted)
		case "compare_share_enable":
			keys = append(keys, metricShareEnabled)
		case "compare_revoke":
			keys = append(keys, metricRevoked)
		}
	}
	if _, ok := tokenResolvingActions[action]; ok && (outcome == "not_found" || outcome == "expired") {
		keys = append(keys, metricTokenResolutionFailures)
	}
	return keys
}

// compareMetrics holds the lifecycle counters keyed by the same keys
// compareMetricKeys returns.
type compareMetrics struct {
	counters map[string]metric.Int64Counter
}

var (
	compareMetricsOnce     sync.Once
	compareMetricsInstance *compareMetrics
)

// getCompareMetrics returns the process-wide comparison metrics, building them
// once from the global MeterProvider. Until an exporter is wired (see
// internal/telemetry), the global provider is a no-op and these counters
// record into the void — the same "instrument now, export later" stance the
// tracer takes.
func getCompareMetrics() *compareMetrics {
	compareMetricsOnce.Do(func() {
		compareMetricsInstance = newCompareMetrics(otel.Meter(compareMeterName))
	})
	return compareMetricsInstance
}

// newCompareMetrics builds the counters against an explicit meter.
func newCompareMetrics(m metric.Meter) *compareMetrics {
	return &compareMetrics{
		counters: map[string]metric.Int64Counter{
			metricInvitesCreated:          compareCounter(m, "echo.compare.invites_created", "Comparison invites created."),
			metricInvitesAccepted:         compareCounter(m, "echo.compare.invites_accepted", "Comparison invites accepted."),
			metricShareEnabled:            compareCounter(m, "echo.compare.share_enabled", "Comparison public-share consents granted."),
			metricRevoked:                 compareCounter(m, "echo.compare.revoked", "Comparisons revoked."),
			metricTokenResolutionFailures: compareCounter(m, "echo.compare.token_resolution_failures", "Comparison token resolutions that failed (not found or expired)."),
		},
	}
}

func compareCounter(m metric.Meter, name, desc string) metric.Int64Counter {
	c, err := m.Int64Counter(name, metric.WithDescription(desc))
	if err != nil {
		// OTel returns a usable no-op instrument alongside the error, so the
		// counter is still safe to call; surface the error non-fatally.
		otel.Handle(err)
	}
	return c
}

// record maps an (action, outcome) lifecycle event to the relevant counters.
// It is safe to call for every audited event; events that map to nothing are
// ignored.
func (cm *compareMetrics) record(action, outcome string) {
	ctx := context.Background()
	for _, key := range compareMetricKeys(action, outcome) {
		if c, ok := cm.counters[key]; ok {
			c.Add(ctx, 1)
		}
	}
}
