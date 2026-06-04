package http

// billing_test.go — tests for billing HTTP handlers (T-MONEY-001).
//
// White-box tests in the same package as the handlers, following the pattern
// of mux_test.go and compare_test.go.
//
// Unit-level service logic is covered in billing/service_test.go.
// These tests verify:
//   - Route registration (billing routes only register when Billing != nil)
//   - Webhook 400 on bad signature when secret is configured
//   - Webhook 200 on valid body / no secret (dev mode)

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/billing"
	"github.com/google/uuid"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ─── route registration ───────────────────────────────────────────────────────

func TestBilling_routesNotRegisteredWithoutBillingService(t *testing.T) {
	mux := NewMux(Dependencies{Logger: slog.Default()})
	for _, path := range []string{
		"/billing/webhooks/stripe",
		"/billing/webhooks/apple",
		"/billing/webhooks/google",
	} {
		req := httptest.NewRequest(http.MethodPost, path, nil)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, req)
		assert.Equal(t, http.StatusNotFound, w.Code,
			"expected 404 for %s when billing not wired", path)
	}
}

// ─── webhook handlers ─────────────────────────────────────────────────────────

func TestStripeWebhookHandler_noSecret_returns200(t *testing.T) {
	// No secret configured → sig check skipped → handler processes event → 200.
	mux := newBillingTestMux(t, "")
	body := `{"type":"payment_intent.created","data":{"object":{"id":"pi_1"}}}`
	req := httptest.NewRequest(http.MethodPost, "/billing/webhooks/stripe",
		strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	require.Equal(t, http.StatusOK, w.Code, w.Body.String())
}

func TestStripeWebhookHandler_badSignature_returns400(t *testing.T) {
	mux := newBillingTestMux(t, "whsec_secret")
	body := `{"type":"payment_intent.created","data":{"object":{"id":"pi_1"}}}`
	req := httptest.NewRequest(http.MethodPost, "/billing/webhooks/stripe",
		strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Stripe-Signature", "t=1,v1=badsig")
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	require.Equal(t, http.StatusBadRequest, w.Code)
}

func TestStripeWebhookHandler_validSignature_returns200(t *testing.T) {
	secret := "whsec_valid"
	mux := newBillingTestMux(t, secret)
	obj := `{"id":"pi_2","status":"requires_payment_method"}`
	body, header := signedStripeWebhook(secret, "payment_intent.created", obj)
	req := httptest.NewRequest(http.MethodPost, "/billing/webhooks/stripe",
		bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Stripe-Signature", header)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	require.Equal(t, http.StatusOK, w.Code, w.Body.String())
}

func TestAppleWebhookHandler_badBody_returns200(t *testing.T) {
	// Apple handler logs the error and returns 200 so Apple doesn't retry.
	mux := newBillingTestMux(t, "")
	req := httptest.NewRequest(http.MethodPost, "/billing/webhooks/apple",
		strings.NewReader("not-json"))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	require.Equal(t, http.StatusOK, w.Code)
}

func TestGoogleWebhookHandler_badBody_returns200(t *testing.T) {
	mux := newBillingTestMux(t, "")
	req := httptest.NewRequest(http.MethodPost, "/billing/webhooks/google",
		strings.NewReader("not-json"))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	require.Equal(t, http.StatusOK, w.Code)
}

// ─── helpers ─────────────────────────────────────────────────────────────────

// newBillingTestMux builds a mux with a real billing.Service (in-memory repo)
// wired. No Postgres required. Auth is nil so authenticated billing routes
// are not registered; webhook routes are public.
func newBillingTestMux(t *testing.T, webhookSecret string) http.Handler {
	t.Helper()
	bs := billing.New(billing.Config{
		Repository:          newBillingFakeRepo(),
		StripeWebhookSecret: webhookSecret,
	})
	deps := Dependencies{
		Logger:  slog.Default(),
		Billing: bs,
		// Users is required for billing routes to register.
		Users: &muxFakeUsers{},
	}
	return NewMux(deps)
}

// signedStripeWebhook mirrors billing.verifyStripeSignature's algorithm.
func signedStripeWebhook(secret, eventType, objJSON string) ([]byte, string) {
	ts := "1717488000"
	dataJSON := fmt.Sprintf(`{"object":%s}`, objJSON)
	body := fmt.Sprintf(`{"type":%q,"data":%s}`, eventType, dataJSON)
	signed := ts + "." + body
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(signed))
	sig := fmt.Sprintf("%x", mac.Sum(nil))
	header := fmt.Sprintf("t=%s,v1=%s", ts, sig)
	return []byte(body), header
}

// ─── in-memory billing.Repository ────────────────────────────────────────────

type billingTestRepo struct {
	mu     sync.Mutex
	byUser map[uuid.UUID]billing.Subscription
}

func newBillingFakeRepo() billing.Repository {
	return &billingTestRepo{byUser: map[uuid.UUID]billing.Subscription{}}
}

func (r *billingTestRepo) Upsert(_ context.Context, sub billing.Subscription) (billing.Subscription, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if sub.ID == uuid.Nil {
		sub.ID = uuid.New()
	}
	r.byUser[sub.UserID] = sub
	return sub, nil
}

func (r *billingTestRepo) GetByUserID(_ context.Context, userID uuid.UUID) (billing.Subscription, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	sub, ok := r.byUser[userID]
	if !ok {
		return billing.Subscription{}, billing.ErrNotFound
	}
	return sub, nil
}

func (r *billingTestRepo) GetByStoreSubscriptionID(_ context.Context, store billing.Store, id string) (billing.Subscription, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, sub := range r.byUser {
		if sub.Store == store && sub.StoreSubscriptionID == id {
			return sub, nil
		}
	}
	return billing.Subscription{}, billing.ErrNotFound
}

func (r *billingTestRepo) GetByStoreCustomerID(_ context.Context, store billing.Store, id string) (billing.Subscription, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, sub := range r.byUser {
		if sub.Store == store && sub.StoreCustomerID == id {
			return sub, nil
		}
	}
	return billing.Subscription{}, billing.ErrNotFound
}

func (r *billingTestRepo) LogEvent(_ context.Context, _ billing.Store, _ string, _ string) error {
	return nil
}
