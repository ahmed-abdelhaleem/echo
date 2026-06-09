// Package http — billing handlers (T-MONEY-001 / F-MONEY-001).
//
// ⚠️  HUMAN REVIEW REQUIRED — this file contains billing logic.
//
//	Per AGENTS.md escalation rule #10, do not merge without explicit
//	human review and approval.
//
// Endpoints:
//
//	GET  /users/me/subscription           — authenticated
//	POST /billing/stripe/checkout         — authenticated; desktop checkout
//	POST /billing/stripe/portal           — authenticated; manage subscription
//	POST /billing/webhooks/stripe         — public; HMAC-verified
//	POST /billing/webhooks/apple          — public; JWS-encoded
//	POST /billing/webhooks/google         — public; Pub/Sub push
//	POST /billing/google/acknowledge      — authenticated; client purchase ack
package http

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/billing"
)

// billingHandlerConfig holds dependencies for billing HTTP handlers.
type billingHandlerConfig struct {
	Billing      *billing.Service
	Users        auth.UsersRepository
	ShareBaseURL string // used to build Stripe success / cancel URLs
	Logger       *slog.Logger
	Now          func() time.Time
}

// billingSubscriptionResponse is the wire shape for GET /users/me/subscription.
type billingSubscriptionResponse struct {
	Tier             string  `json:"tier"`
	Status           string  `json:"status"`
	Store            string  `json:"store"`
	IsPremium        bool    `json:"is_premium"`
	CurrentPeriodEnd *string `json:"current_period_end,omitempty"`
}

// getSubscriptionHandler handles GET /users/me/subscription.
func getSubscriptionHandler(cfg billingHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "session required"})
			return
		}

		now := cfg.Now
		if now == nil {
			now = time.Now
		}
		user, err := cfg.Users.EnsureFromSession(r.Context(), sess, now())
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "user not found"})
			return
		}

		sub, err := cfg.Billing.GetOrDefault(r.Context(), user.ID)
		if err != nil {
			cfg.Logger.Error("billing: get or default", "err", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
			return
		}

		resp := billingSubscriptionResponse{
			Tier:      string(sub.Tier),
			Status:    string(sub.Status),
			Store:     string(sub.Store),
			IsPremium: sub.IsPremium(),
		}
		if sub.CurrentPeriodEnd != nil {
			s := sub.CurrentPeriodEnd.UTC().Format(time.RFC3339)
			resp.CurrentPeriodEnd = &s
		}

		writeJSON(w, http.StatusOK, resp)
	}
}

// stripeCheckoutRequest is the body for POST /billing/stripe/checkout.
type stripeCheckoutRequest struct {
	PriceID string `json:"price_id"` // optional; defaults to monthly plan
}

// stripeCheckoutResponse is the wire shape for POST /billing/stripe/checkout.
type stripeCheckoutResponse struct {
	SessionID string `json:"session_id"`
	URL       string `json:"url"`
}

// createStripeCheckoutHandler handles POST /billing/stripe/checkout.
func createStripeCheckoutHandler(cfg billingHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "session required"})
			return
		}

		now := cfg.Now
		if now == nil {
			now = time.Now
		}
		user, err := cfg.Users.EnsureFromSession(r.Context(), sess, now())
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "user not found"})
			return
		}

		var req stripeCheckoutRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			// Tolerate empty body — default plan is fine.
			req = stripeCheckoutRequest{}
		}

		base := cfg.ShareBaseURL
		if base == "" {
			base = "http://localhost:3000"
		}
		out, err := cfg.Billing.CreateStripeCheckoutSession(r.Context(), billing.StripeCheckoutInput{
			UserID:     user.ID,
			UserEmail:  sess.Email,
			PriceID:    req.PriceID,
			SuccessURL: base + "/subscription/success?session_id={CHECKOUT_SESSION_ID}",
			CancelURL:  base + "/subscription",
		})
		if err != nil {
			cfg.Logger.Error("billing: stripe checkout", "err", err)
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "payment provider error"})
			return
		}

		writeJSON(w, http.StatusCreated, stripeCheckoutResponse{
			SessionID: out.SessionID,
			URL:       out.URL,
		})
	}
}

// stripePortalResponse is the wire shape for POST /billing/stripe/portal.
type stripePortalResponse struct {
	URL string `json:"url"`
}

// createStripePortalHandler handles POST /billing/stripe/portal.
func createStripePortalHandler(cfg billingHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "session required"})
			return
		}

		now := cfg.Now
		if now == nil {
			now = time.Now
		}
		user, err := cfg.Users.EnsureFromSession(r.Context(), sess, now())
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "user not found"})
			return
		}

		base := cfg.ShareBaseURL
		if base == "" {
			base = "http://localhost:3000"
		}
		out, err := cfg.Billing.CreateStripePortalSession(r.Context(), billing.StripePortalInput{
			UserID:    user.ID,
			ReturnURL: base + "/subscription",
		})
		if err != nil {
			cfg.Logger.Error("billing: stripe portal", "err", err)
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "payment provider error"})
			return
		}

		writeJSON(w, http.StatusCreated, stripePortalResponse{URL: out.URL})
	}
}

// stripeWebhookHandler handles POST /billing/webhooks/stripe.
// The raw body must be preserved for HMAC verification — this handler
// reads the body directly and does NOT use readJSON.
func stripeWebhookHandler(cfg billingHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20)) // 1 MB limit
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "read body"})
			return
		}

		sigHeader := r.Header.Get("Stripe-Signature")
		if err := cfg.Billing.HandleStripeWebhook(r.Context(), body, sigHeader); err != nil {
			cfg.Logger.Error("billing: stripe webhook", "err", err, "sig", sigHeader)
			// Return 400 on signature error so Stripe retries (it will log the failure).
			// Return 200 on "unknown customer" (we may receive events before client acks purchase).
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{"received": "ok"})
	}
}

// appleWebhookHandler handles POST /billing/webhooks/apple.
func appleWebhookHandler(cfg billingHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "read body"})
			return
		}

		if err := cfg.Billing.HandleAppleNotification(r.Context(), body); err != nil {
			cfg.Logger.Error("billing: apple webhook", "err", err)
			// 200 — Apple retries on non-200; log the error but don't block.
		}

		writeJSON(w, http.StatusOK, map[string]string{"received": "ok"})
	}
}

// googleWebhookHandler handles POST /billing/webhooks/google.
func googleWebhookHandler(cfg billingHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "read body"})
			return
		}

		if err := cfg.Billing.HandleGoogleNotification(r.Context(), body); err != nil {
			cfg.Logger.Error("billing: google webhook", "err", err)
		}

		writeJSON(w, http.StatusOK, map[string]string{"received": "ok"})
	}
}

// googleAcknowledgeRequest is the body for POST /billing/google/acknowledge.
type googleAcknowledgeRequest struct {
	PurchaseToken  string `json:"purchase_token"`
	SubscriptionID string `json:"subscription_id"`
}

// googleAcknowledgeHandler handles POST /billing/google/acknowledge.
// Called by the Android client after a successful Play Billing purchase to
// create the initial subscription DB row (required so subsequent Pub/Sub
// notifications can be matched to the user).
func googleAcknowledgeHandler(cfg billingHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "session required"})
			return
		}

		now := cfg.Now
		if now == nil {
			now = time.Now
		}
		user, err := cfg.Users.EnsureFromSession(r.Context(), sess, now())
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "user not found"})
			return
		}

		var req googleAcknowledgeRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.PurchaseToken == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "purchase_token required"})
			return
		}

		if err := cfg.Billing.AcknowledgeGooglePurchase(r.Context(), user.ID, req.PurchaseToken, req.SubscriptionID); err != nil {
			cfg.Logger.Error("billing: google acknowledge", "err", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{"acknowledged": "ok"})
	}
}
