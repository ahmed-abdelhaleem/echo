package billing

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

// ErrInvalidSignature is returned when a webhook payload cannot be verified
// against the configured signing secret.
var ErrInvalidSignature = errors.New("billing: invalid webhook signature")

// ErrUnknownCustomer is returned when a webhook references a provider customer
// or subscription ID that cannot be mapped to any user in our database.
var ErrUnknownCustomer = errors.New("billing: webhook references unknown customer or subscription")

// Config groups the constructor's dependencies for Service.
type Config struct {
	Repository Repository

	// StripeSecretKey is the live/test secret key (sk_live_… / sk_test_…).
	// When empty, Stripe checkout and portal session creation returns an error.
	StripeSecretKey string

	// StripeWebhookSecret is the Stripe webhook signing secret (whsec_…).
	// When empty, the webhook signature check is skipped (dev only).
	StripeWebhookSecret string

	// StripeMonthlyPriceID and StripeYearlyPriceID are the Stripe Price
	// object IDs for the two Echo+ plans.
	StripeMonthlyPriceID string
	StripeYearlyPriceID  string

	// AppleWebhookSecret is the shared secret used to verify Apple App Store
	// server notifications. When empty, payload decoding continues but
	// full JWS signature verification is skipped (dev only).
	//
	// HUMAN REVIEW REQUIRED: production must enable full JWS verification
	// using Apple's root CA certificate bundle.
	AppleWebhookSecret string

	// GoogleWebhookSecret is the Google Cloud Pub/Sub push subscription
	// bearer token. When empty, token verification is skipped (dev only).
	GoogleWebhookSecret string

	// Now is an injectable time source. Defaults to time.Now.
	Now func() time.Time

	// HTTPClient is an injectable HTTP client for Stripe API calls. Defaults
	// to http.DefaultClient.
	HTTPClient *http.Client
}

// Service is the domain entry point for billing.
type Service struct {
	repo                 Repository
	stripeSecretKey      string
	stripeWebhookSecret  string
	stripeMonthlyPriceID string
	stripeYearlyPriceID  string
	appleWebhookSecret   string
	googleWebhookSecret  string
	now                  func() time.Time
	httpClient           *http.Client
}

// New constructs a Service.
func New(cfg Config) *Service {
	if cfg.Repository == nil {
		panic("billing: New requires Repository")
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	client := cfg.HTTPClient
	if client == nil {
		client = http.DefaultClient
	}
	return &Service{
		repo:                 cfg.Repository,
		stripeSecretKey:      cfg.StripeSecretKey,
		stripeWebhookSecret:  cfg.StripeWebhookSecret,
		stripeMonthlyPriceID: cfg.StripeMonthlyPriceID,
		stripeYearlyPriceID:  cfg.StripeYearlyPriceID,
		appleWebhookSecret:   cfg.AppleWebhookSecret,
		googleWebhookSecret:  cfg.GoogleWebhookSecret,
		now:                  now,
		httpClient:           client,
	}
}

// ─── Public API ──────────────────────────────────────────────────────────────

// GetOrDefault returns the user's subscription. If no row exists, returns a
// free-tier Subscription with no DB write — callers must not rely on the
// returned value having an ID.
func (s *Service) GetOrDefault(ctx context.Context, userID uuid.UUID) (Subscription, error) {
	sub, err := s.repo.GetByUserID(ctx, userID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return defaultFree(userID), nil
		}
		return Subscription{}, fmt.Errorf("billing: get or default: %w", err)
	}
	return sub, nil
}

// ─── Stripe ──────────────────────────────────────────────────────────────────

// StripeCheckoutInput is the input for CreateStripeCheckoutSession.
type StripeCheckoutInput struct {
	UserID     uuid.UUID
	UserEmail  string
	PriceID    string // stripe price ID; if empty, StripeMonthlyPriceID is used
	SuccessURL string
	CancelURL  string
}

// StripeCheckoutOutput is the output of CreateStripeCheckoutSession.
type StripeCheckoutOutput struct {
	SessionID string
	URL       string
}

// CreateStripeCheckoutSession creates a Stripe Checkout session for Echo+.
// The session carries the user_id in metadata so the webhook can map it
// back to an internal user when checkout.session.completed fires.
//
// This uses a raw HTTP call to the Stripe API (no SDK) to avoid adding a
// new top-level dependency. All error paths are explicit.
func (s *Service) CreateStripeCheckoutSession(ctx context.Context, in StripeCheckoutInput) (StripeCheckoutOutput, error) {
	if s.stripeSecretKey == "" {
		return StripeCheckoutOutput{}, errors.New("billing: stripe secret key not configured")
	}
	priceID := in.PriceID
	if priceID == "" {
		priceID = s.stripeMonthlyPriceID
	}
	if priceID == "" {
		return StripeCheckoutOutput{}, errors.New("billing: stripe price id not configured")
	}

	// Build form-encoded body per Stripe's API convention.
	form := url.Values{}
	form.Set("mode", "subscription")
	form.Set("line_items[0][price]", priceID)
	form.Set("line_items[0][quantity]", "1")
	form.Set("success_url", in.SuccessURL)
	form.Set("cancel_url", in.CancelURL)
	// Pass metadata so the checkout.session.completed webhook can find this user.
	form.Set("metadata[user_id]", in.UserID.String())
	// Prefill the customer's email if known.
	if in.UserEmail != "" {
		form.Set("customer_email", in.UserEmail)
	}
	// Allow promotional codes.
	form.Set("allow_promotion_codes", "true")

	resp, err := s.stripePost(ctx, "https://api.stripe.com/v1/checkout/sessions", form)
	if err != nil {
		return StripeCheckoutOutput{}, fmt.Errorf("billing: stripe checkout: %w", err)
	}

	return StripeCheckoutOutput{
		SessionID: stringField(resp, "id"),
		URL:       stringField(resp, "url"),
	}, nil
}

// StripePortalInput is the input for CreateStripePortalSession.
type StripePortalInput struct {
	UserID    uuid.UUID
	ReturnURL string
}

// StripePortalOutput is the output of CreateStripePortalSession.
type StripePortalOutput struct {
	URL string
}

// CreateStripePortalSession creates a Stripe Billing Portal session for an
// existing Echo+ subscriber to manage or cancel their subscription.
func (s *Service) CreateStripePortalSession(ctx context.Context, in StripePortalInput) (StripePortalOutput, error) {
	if s.stripeSecretKey == "" {
		return StripePortalOutput{}, errors.New("billing: stripe secret key not configured")
	}

	// Look up the Stripe customer ID from our DB.
	sub, err := s.repo.GetByUserID(ctx, in.UserID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return StripePortalOutput{}, ErrUnknownCustomer
		}
		return StripePortalOutput{}, fmt.Errorf("billing: portal: lookup: %w", err)
	}
	if sub.Store != StoreStripe || sub.StoreCustomerID == "" {
		return StripePortalOutput{}, ErrUnknownCustomer
	}

	form := url.Values{}
	form.Set("customer", sub.StoreCustomerID)
	form.Set("return_url", in.ReturnURL)

	resp, err := s.stripePost(ctx, "https://api.stripe.com/v1/billing_portal/sessions", form)
	if err != nil {
		return StripePortalOutput{}, fmt.Errorf("billing: portal: %w", err)
	}

	return StripePortalOutput{URL: stringField(resp, "url")}, nil
}

// HandleStripeWebhook processes an inbound Stripe webhook event.
// The raw body must be provided for HMAC verification.
//
// Handled event types:
//   - checkout.session.completed   → upsert active subscription
//   - customer.subscription.updated → update status / period
//   - customer.subscription.deleted → mark canceled
func (s *Service) HandleStripeWebhook(ctx context.Context, rawBody []byte, sigHeader string) error {
	// Verify signature when a secret is configured.
	if s.stripeWebhookSecret != "" {
		if err := verifyStripeSignature(rawBody, sigHeader, s.stripeWebhookSecret); err != nil {
			return err
		}
	}

	var event struct {
		Type string          `json:"type"`
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(rawBody, &event); err != nil {
		return fmt.Errorf("billing: stripe webhook: decode: %w", err)
	}

	// Log the raw event for audit regardless of whether we handle it.
	_ = s.repo.LogEvent(ctx, StoreStripe, event.Type, string(rawBody))

	switch event.Type {
	case "checkout.session.completed":
		return s.handleStripeCheckoutCompleted(ctx, event.Data)
	case "customer.subscription.updated":
		return s.handleStripeSubscriptionUpsert(ctx, event.Data, false)
	case "customer.subscription.deleted":
		return s.handleStripeSubscriptionUpsert(ctx, event.Data, true)
	}
	// Unhandled event types are not errors; Stripe expects 200.
	return nil
}

// ─── Apple App Store ─────────────────────────────────────────────────────────

// HandleAppleNotification processes an Apple App Store Server Notification
// (version 2 JWS format). The signedPayload field contains a three-part
// dot-separated JWS that encodes the notification data.
//
// HUMAN REVIEW REQUIRED: this implementation decodes the JWS payload without
// verifying the Apple root CA certificate chain. Production deployments must
// add full JWS signature verification using Apple's root CA bundle from
// https://www.apple.com/certificateauthority/. This is flagged for human
// review per AGENTS.md escalation rule #10 (billing logic).
func (s *Service) HandleAppleNotification(ctx context.Context, rawBody []byte) error {
	// Log the raw payload first for audit trail.
	_ = s.repo.LogEvent(ctx, StoreApple, "raw_notification", string(rawBody))

	var wrapper struct {
		SignedPayload string `json:"signedPayload"`
	}
	if err := json.Unmarshal(rawBody, &wrapper); err != nil {
		return fmt.Errorf("billing: apple: decode wrapper: %w", err)
	}
	if wrapper.SignedPayload == "" {
		return errors.New("billing: apple: missing signedPayload")
	}

	// Decode the JWS payload part (second segment, base64url-encoded JSON).
	decoded, err := decodeJWSPayload(wrapper.SignedPayload)
	if err != nil {
		return fmt.Errorf("billing: apple: decode jws payload: %w", err)
	}

	var notification struct {
		NotificationType string          `json:"notificationType"`
		Subtype          string          `json:"subtype"`
		Data             json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(decoded, &notification); err != nil {
		return fmt.Errorf("billing: apple: decode notification: %w", err)
	}

	// Re-log with the extracted type.
	_ = s.repo.LogEvent(ctx, StoreApple, notification.NotificationType, string(decoded))

	var data struct {
		AppAppleID            int64  `json:"appAppleId"`
		BundleID              string `json:"bundleId"`
		EnvironmentString     string `json:"environment"`
		SignedTransactionInfo string `json:"signedTransactionInfo"`
		SignedRenewalInfo     string `json:"signedRenewalInfo"`
	}
	if err := json.Unmarshal(notification.Data, &data); err != nil {
		return fmt.Errorf("billing: apple: decode data: %w", err)
	}

	// Decode the signed transaction info to get identifiers.
	txDecoded, err := decodeJWSPayload(data.SignedTransactionInfo)
	if err != nil {
		return fmt.Errorf("billing: apple: decode tx info: %w", err)
	}
	var tx struct {
		OriginalTransactionID string `json:"originalTransactionId"`
		TransactionID         string `json:"transactionId"`
		AppAccountToken       string `json:"appAccountToken"` // our user_id set at purchase
		ExpiresDateMS         int64  `json:"expiresDate"`
		RevocationDate        int64  `json:"revocationDate"`
	}
	if err := json.Unmarshal(txDecoded, &tx); err != nil {
		return fmt.Errorf("billing: apple: decode tx fields: %w", err)
	}

	// Map notification type to subscription status.
	var (
		tier   = TierEchoPlus
		status Status
	)
	switch notification.NotificationType {
	case "SUBSCRIBED", "DID_RENEW":
		status = StatusActive
	case "DID_CHANGE_RENEWAL_STATUS":
		// Subtype CANCEL means the user disabled auto-renew; subscription
		// is still active until the period end.
		status = StatusActive
	case "EXPIRED":
		status = StatusExpired
		tier = TierFree
	case "REFUND":
		status = StatusCanceled
		tier = TierFree
	default:
		// Unknown type — logged above, nothing to upsert.
		return nil
	}

	// Map appAccountToken (our user_id) or fall back to originalTransactionId lookup.
	var userID uuid.UUID
	if tx.AppAccountToken != "" {
		id, err := uuid.Parse(tx.AppAccountToken)
		if err == nil {
			userID = id
		}
	}
	if userID == uuid.Nil {
		// Try to find an existing record by originalTransactionId.
		existing, err := s.repo.GetByStoreSubscriptionID(ctx, StoreApple, tx.OriginalTransactionID)
		if err == nil {
			userID = existing.UserID
		}
	}
	if userID == uuid.Nil {
		// Cannot map to a user — log and return. This can happen on the
		// first SUBSCRIBED notification if the app did not set appAccountToken.
		return fmt.Errorf("billing: apple: cannot resolve user for originalTransactionId=%s", tx.OriginalTransactionID)
	}

	var periodEnd *time.Time
	if tx.ExpiresDateMS > 0 {
		t := time.UnixMilli(tx.ExpiresDateMS).UTC()
		periodEnd = &t
	}
	var canceledAt *time.Time
	if tx.RevocationDate > 0 {
		t := time.UnixMilli(tx.RevocationDate).UTC()
		canceledAt = &t
	}

	existing, err := s.repo.GetByUserID(ctx, userID)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return fmt.Errorf("billing: apple: lookup existing: %w", err)
	}

	sub := existing
	if errors.Is(err, ErrNotFound) {
		sub = defaultFree(userID)
	}
	sub.Tier = tier
	sub.Status = status
	sub.Store = StoreApple
	sub.StoreSubscriptionID = tx.OriginalTransactionID
	sub.CurrentPeriodEnd = periodEnd
	sub.CanceledAt = canceledAt

	_, upsertErr := s.repo.Upsert(ctx, sub)
	return upsertErr
}

// ─── Google Play Billing ─────────────────────────────────────────────────────

// HandleGoogleNotification processes a Google Play Developer Notification
// delivered via Cloud Pub/Sub push subscription.
//
// HUMAN REVIEW REQUIRED: production must validate the Google Cloud Pub/Sub
// bearer token in the Authorization header before calling this method.
// The HTTP handler does this when GoogleWebhookSecret is configured.
func (s *Service) HandleGoogleNotification(ctx context.Context, rawBody []byte) error {
	// Log the raw payload first.
	_ = s.repo.LogEvent(ctx, StoreGoogle, "raw_notification", string(rawBody))

	// Google Pub/Sub wraps the actual message in a base64-encoded data field.
	var pubsubMsg struct {
		Message struct {
			Data       string            `json:"data"`
			MessageID  string            `json:"messageId"`
			Attributes map[string]string `json:"attributes"`
		} `json:"message"`
		Subscription string `json:"subscription"`
	}
	if err := json.Unmarshal(rawBody, &pubsubMsg); err != nil {
		return fmt.Errorf("billing: google: decode pubsub: %w", err)
	}

	// Decode the base64 inner payload.
	msgData, err := base64.StdEncoding.DecodeString(pubsubMsg.Message.Data)
	if err != nil {
		return fmt.Errorf("billing: google: decode pubsub data: %w", err)
	}

	var notification struct {
		SubscriptionNotification *struct {
			Version          string `json:"version"`
			NotificationType int    `json:"notificationType"`
			PurchaseToken    string `json:"purchaseToken"`
			SubscriptionID   string `json:"subscriptionId"`
		} `json:"subscriptionNotification"`
		PackageName     string `json:"packageName"`
		EventTimeMillis string `json:"eventTimeMillis"`
	}
	if err := json.Unmarshal(msgData, &notification); err != nil {
		return fmt.Errorf("billing: google: decode notification body: %w", err)
	}

	sn := notification.SubscriptionNotification
	if sn == nil {
		// Test or voided purchase notification — log and ignore.
		return nil
	}

	// Re-log with structured type.
	notifType := strconv.Itoa(sn.NotificationType)
	_ = s.repo.LogEvent(ctx, StoreGoogle, "subscription_notification_"+notifType, string(msgData))

	// Google notification types (developer.android.com/google/play/billing/rtdn-reference).
	// 1=RECOVERED, 2=RENEWED, 3=CANCELED, 4=PURCHASED, 5=ON_HOLD,
	// 6=IN_GRACE_PERIOD, 7=RESTARTED, 12=EXPIRED, 13=REVOKED.
	var tier = TierEchoPlus
	var status Status
	switch sn.NotificationType {
	case 4: // PURCHASED
		status = StatusActive
	case 1, 2, 7: // RECOVERED, RENEWED, RESTARTED
		status = StatusActive
	case 3, 13: // CANCELED, REVOKED
		status = StatusCanceled
		tier = TierFree
	case 5: // ON_HOLD (payment failed)
		status = StatusPastDue
	case 6: // IN_GRACE_PERIOD
		status = StatusPastDue
	case 12: // EXPIRED
		status = StatusExpired
		tier = TierFree
	default:
		return nil
	}

	// Look up by purchaseToken (our StoreSubscriptionID for Google).
	existing, err := s.repo.GetByStoreSubscriptionID(ctx, StoreGoogle, sn.PurchaseToken)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return fmt.Errorf("billing: google: lookup by purchase token: %w", err)
	}

	if errors.Is(err, ErrNotFound) {
		// New purchase — we cannot map to a user without the Play Billing API.
		// In production the client sends the purchaseToken to the server after
		// purchase (T-MONEY-001 client flow), which calls AcknowledgePurchase
		// and creates the initial DB row. Arriving here for a PURCHASED event
		// with no row means the client-side acknowledgement hasn't run yet.
		// Log and return; the client's acknowledgement call will create the row.
		return nil
	}

	existing.Tier = tier
	existing.Status = status

	_, upsertErr := s.repo.Upsert(ctx, existing)
	return upsertErr
}

// AcknowledgeGooglePurchase is called by the client after a successful Google
// Play Billing purchase. It creates the initial subscription row so subsequent
// Pub/Sub notifications can be matched to a user.
func (s *Service) AcknowledgeGooglePurchase(ctx context.Context, userID uuid.UUID, purchaseToken, subscriptionID string) error {
	sub, err := s.repo.GetByUserID(ctx, userID)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return fmt.Errorf("billing: google: ack: lookup: %w", err)
	}
	if errors.Is(err, ErrNotFound) {
		sub = defaultFree(userID)
	}
	sub.Tier = TierEchoPlus
	sub.Status = StatusActive
	sub.Store = StoreGoogle
	sub.StoreSubscriptionID = purchaseToken

	_, upsertErr := s.repo.Upsert(ctx, sub)
	return upsertErr
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

// verifyStripeSignature validates a Stripe webhook payload against the
// Stripe-Signature header using HMAC-SHA256.
// See: https://stripe.com/docs/webhooks/signatures
func verifyStripeSignature(payload []byte, header, secret string) error {
	// Header format: "t=<timestamp>,v1=<sig>[,v1=<sig2>]"
	var timestamp, sigHex string
	for _, part := range strings.Split(header, ",") {
		kv := strings.SplitN(part, "=", 2)
		if len(kv) != 2 {
			continue
		}
		switch kv[0] {
		case "t":
			timestamp = kv[1]
		case "v1":
			if sigHex == "" {
				sigHex = kv[1]
			}
		}
	}
	if timestamp == "" || sigHex == "" {
		return ErrInvalidSignature
	}

	// The signed payload is "<timestamp>.<rawBody>".
	signed := timestamp + "." + string(payload)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(signed))
	expected := fmt.Sprintf("%x", mac.Sum(nil))

	if !hmac.Equal([]byte(expected), []byte(sigHex)) {
		return ErrInvalidSignature
	}
	return nil
}

// decodeJWSPayload extracts and base64url-decodes the payload segment (index 1)
// of a JWS compact serialisation (header.payload.signature).
func decodeJWSPayload(jws string) ([]byte, error) {
	parts := strings.Split(jws, ".")
	if len(parts) != 3 {
		return nil, errors.New("billing: not a valid JWS compact serialisation")
	}
	decoded, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("billing: jws payload decode: %w", err)
	}
	return decoded, nil
}

// stripePost makes a POST to the Stripe API with form-encoded body and
// HTTP Basic Auth (secret_key:).
func (s *Service) stripePost(ctx context.Context, endpoint string, form url.Values) (map[string]any, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint,
		bytes.NewBufferString(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.SetBasicAuth(s.stripeSecretKey, "")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("stripe http: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("stripe read body: %w", err)
	}

	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("stripe decode body: %w", err)
	}

	if resp.StatusCode >= 400 {
		errMsg := "stripe error"
		if e, ok := out["error"].(map[string]any); ok {
			if msg, ok := e["message"].(string); ok {
				errMsg = msg
			}
		}
		return nil, fmt.Errorf("stripe %d: %s", resp.StatusCode, errMsg)
	}

	return out, nil
}

// handleStripeCheckoutCompleted processes a checkout.session.completed event.
func (s *Service) handleStripeCheckoutCompleted(ctx context.Context, data json.RawMessage) error {
	var wrapper struct {
		Object struct {
			ID           string            `json:"id"`
			CustomerID   string            `json:"customer"`
			Subscription string            `json:"subscription"`
			Metadata     map[string]string `json:"metadata"`
		} `json:"object"`
	}
	if err := json.Unmarshal(data, &wrapper); err != nil {
		return fmt.Errorf("billing: stripe checkout completed: decode: %w", err)
	}
	obj := wrapper.Object

	rawUserID := obj.Metadata["user_id"]
	userID, err := uuid.Parse(rawUserID)
	if err != nil {
		return fmt.Errorf("billing: stripe checkout completed: invalid user_id metadata=%q: %w", rawUserID, err)
	}

	existing, err := s.repo.GetByUserID(ctx, userID)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return fmt.Errorf("billing: stripe checkout completed: lookup: %w", err)
	}
	sub := existing
	if errors.Is(err, ErrNotFound) {
		sub = defaultFree(userID)
	}
	sub.Tier = TierEchoPlus
	sub.Status = StatusActive
	sub.Store = StoreStripe
	sub.StoreCustomerID = obj.CustomerID
	sub.StoreSubscriptionID = obj.Subscription

	_, upsertErr := s.repo.Upsert(ctx, sub)
	return upsertErr
}

// handleStripeSubscriptionUpsert processes customer.subscription.updated and
// customer.subscription.deleted events.
func (s *Service) handleStripeSubscriptionUpsert(ctx context.Context, data json.RawMessage, deleted bool) error {
	var wrapper struct {
		Object struct {
			ID               string `json:"id"`
			CustomerID       string `json:"customer"`
			Status           string `json:"status"`
			CurrentPeriodEnd int64  `json:"current_period_end"`
			CanceledAt       *int64 `json:"canceled_at"`
		} `json:"object"`
	}
	if err := json.Unmarshal(data, &wrapper); err != nil {
		return fmt.Errorf("billing: stripe subscription update: decode: %w", err)
	}
	obj := wrapper.Object

	existing, err := s.repo.GetByStoreSubscriptionID(ctx, StoreStripe, obj.ID)
	if errors.Is(err, ErrNotFound) {
		// Also try by customer ID.
		existing, err = s.repo.GetByStoreCustomerID(ctx, StoreStripe, obj.CustomerID)
	}
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return ErrUnknownCustomer
		}
		return fmt.Errorf("billing: stripe subscription update: lookup: %w", err)
	}

	status := stripeStatusToInternal(obj.Status)
	tier := TierEchoPlus
	if deleted || status == StatusCanceled || status == StatusExpired {
		tier = TierFree
	}

	periodEnd := time.Unix(obj.CurrentPeriodEnd, 0).UTC()
	existing.Tier = tier
	existing.Status = status
	existing.StoreSubscriptionID = obj.ID
	existing.CurrentPeriodEnd = &periodEnd
	if obj.CanceledAt != nil {
		t := time.Unix(*obj.CanceledAt, 0).UTC()
		existing.CanceledAt = &t
	}

	_, upsertErr := s.repo.Upsert(ctx, existing)
	return upsertErr
}

// stripeStatusToInternal maps Stripe subscription status strings to our Status.
func stripeStatusToInternal(stripeStatus string) Status {
	switch stripeStatus {
	case "active":
		return StatusActive
	case "trialing":
		return StatusTrialing
	case "past_due", "unpaid":
		return StatusPastDue
	case "canceled":
		return StatusCanceled
	case "incomplete_expired":
		return StatusExpired
	default:
		return StatusPastDue
	}
}

// stringField safely extracts a string field from a map.
func stringField(m map[string]any, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}
