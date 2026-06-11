package http

import (
	"reflect"
	"testing"
)

func TestCompareMetricKeys(t *testing.T) {
	cases := []struct {
		name    string
		action  string
		outcome string
		want    []string
	}{
		{"invite created", "compare_invite_create", "success", []string{metricInvitesCreated}},
		{"invite accepted", "compare_accept", "success", []string{metricInvitesAccepted}},
		{"share enabled", "compare_share_enable", "success", []string{metricShareEnabled}},
		{"revoked", "compare_revoke", "success", []string{metricRevoked}},
		{"get not found is token failure", "compare_get", "not_found", []string{metricTokenResolutionFailures}},
		{"accept expired is token failure", "compare_accept", "expired", []string{metricTokenResolutionFailures}},
		{"portrait not found is token failure", "compare_portrait_get", "not_found", []string{metricTokenResolutionFailures}},
		// invite_create "not_found" is a playthrough miss, NOT a token miss.
		{"invite not_found is not a token failure", "compare_invite_create", "not_found", nil},
		// outcomes that map to no counter.
		{"rate limited maps to nothing", "compare_accept", "rate_limited", nil},
		{"unknown action maps to nothing", "compare_other", "success", nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := compareMetricKeys(tc.action, tc.outcome)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("compareMetricKeys(%q, %q) = %v, want %v", tc.action, tc.outcome, got, tc.want)
			}
		})
	}
}

func TestCompareMetricsRecordIsSafeWithNoopMeter(t *testing.T) {
	// newCompareMetrics with the no-op global meter must build and record
	// without panicking (the MeterProvider is a no-op until an exporter is
	// wired). This also exercises that every mapped key has a counter.
	cm := getCompareMetrics()
	for _, action := range []string{
		"compare_invite_create",
		"compare_accept",
		"compare_share_enable",
		"compare_revoke",
		"compare_get",
		"compare_portrait_get",
	} {
		cm.record(action, "success")
		cm.record(action, "not_found")
		cm.record(action, "expired")
	}
	// Every key the mapper can emit must resolve to a constructed counter.
	for _, key := range []string{
		metricInvitesCreated,
		metricInvitesAccepted,
		metricShareEnabled,
		metricRevoked,
		metricTokenResolutionFailures,
	} {
		if _, ok := cm.counters[key]; !ok {
			t.Errorf("counter %q not constructed", key)
		}
	}
}

func TestCompareAuditDoesNotPanicWithoutMeterProvider(t *testing.T) {
	cfg := compareHandlerConfig{}
	cfg.audit("compare_invite_create", "success")
	cfg.audit("compare_get", "not_found")
}
