package billing_test

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/billing"
	"github.com/google/uuid"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ─── in-memory fake ──────────────────────────────────────────────────────────

type fakeRepo struct {
	mu     sync.Mutex
	byUser map[uuid.UUID]billing.Subscription
	events []string
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{byUser: map[uuid.UUID]billing.Subscription{}}
}

func (r *fakeRepo) Upsert(_ context.Context, sub billing.Subscription) (billing.Subscription, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if sub.ID == uuid.Nil {
		sub.ID = uuid.New()
	}
	r.byUser[sub.UserID] = sub
	return sub, nil
}

func (r *fakeRepo) GetByUserID(_ context.Context, userID uuid.UUID) (billing.Subscription, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	sub, ok := r.byUser[userID]
	if !ok {
		return billing.Subscription{}, billing.ErrNotFound
	}
	return sub, nil
}

func (r *fakeRepo) GetByStoreSubscriptionID(_ context.Context, store billing.Store, id string) (billing.Subscription, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, sub := range r.byUser {
		if sub.Store == store && sub.StoreSubscriptionID == id {
			return sub, nil
		}
	}
	return billing.Subscription{}, billing.ErrNotFound
}

func (r *fakeRepo) GetByStoreCustomerID(_ context.Context, store billing.Store, id string) (billing.Subscription, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, sub := range r.byUser {
		if sub.Store == store && sub.StoreCustomerID == id {
			return sub, nil
		}
	}
	return billing.Subscription{}, billing.ErrNotFound
}

func (r *fakeRepo) LogEvent(_ context.Context, _ billing.Store, _ string, payload string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, payload)
	return nil
}

// ─── helpers ─────────────────────────────────────────────────────────────────

func makeService(repo billing.Repository) *billing.Service {
	return billing.New(billing.Config{
		Repository: repo,
		Now:        func() time.Time { return time.Date(2026, 6, 4, 12, 0, 0, 0, time.UTC) },
	})
}

// buildStripeWebhookBody returns a stripe event body and a valid Stripe-Signature
// header using the same HMAC-SHA256 algorithm as verifyStripeSignature.
func buildStripeWebhookBody(secret, eventType, objJSON string) ([]byte, string) {
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

// fakeJWS creates a three-part compact JWS with the payload encoded as
// base64url JSON. Not cryptographically valid but sufficient for unit tests.
func fakeJWS(payload map[string]any) string {
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"ES256"}`))
	payloadBytes, _ := json.Marshal(payload)
	payloadEnc := base64.RawURLEncoding.EncodeToString(payloadBytes)
	return hdr + "." + payloadEnc + ".fakesig"
}

// mustJSON marshals to []byte, panicking on error (test-only helper).
func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

// ─── GetOrDefault tests ───────────────────────────────────────────────────────

func TestGetOrDefault_noRow(t *testing.T) {
	repo := newFakeRepo()
	svc := makeService(repo)
	userID := uuid.New()
	sub, err := svc.GetOrDefault(context.Background(), userID)
	require.NoError(t, err)
	assert.Equal(t, billing.TierFree, sub.Tier)
	assert.Equal(t, billing.StatusActive, sub.Status)
	assert.False(t, sub.IsPremium())
}

func TestGetOrDefault_echoPlus(t *testing.T) {
	repo := newFakeRepo()
	svc := makeService(repo)
	userID := uuid.New()
	_, err := repo.Upsert(context.Background(), billing.Subscription{
		UserID: userID, Tier: billing.TierEchoPlus, Status: billing.StatusActive, Store: billing.StoreStripe,
	})
	require.NoError(t, err)
	sub, err := svc.GetOrDefault(context.Background(), userID)
	require.NoError(t, err)
	assert.True(t, sub.IsPremium())
}

// ─── IsPremium tests ──────────────────────────────────────────────────────────

func TestIsPremium(t *testing.T) {
	cases := []struct {
		tier   billing.Tier
		status billing.Status
		want   bool
	}{
		{billing.TierEchoPlus, billing.StatusActive, true},
		{billing.TierEchoPlus, billing.StatusTrialing, true},
		{billing.TierEchoPlus, billing.StatusPastDue, false},
		{billing.TierEchoPlus, billing.StatusCanceled, false},
		{billing.TierEchoPlus, billing.StatusExpired, false},
		{billing.TierFree, billing.StatusActive, false},
	}
	for _, tc := range cases {
		sub := billing.Subscription{Tier: tc.tier, Status: tc.status}
		assert.Equal(t, tc.want, sub.IsPremium(), "tier=%s status=%s", tc.tier, tc.status)
	}
}

// ─── Stripe webhook tests ─────────────────────────────────────────────────────

func TestHandleStripeWebhook_checkoutCompleted(t *testing.T) {
	repo := newFakeRepo()
	secret := "whsec_test"
	svc := billing.New(billing.Config{Repository: repo, StripeWebhookSecret: secret})
	userID := uuid.New()
	obj := fmt.Sprintf(
		`{"id":"cs_test","customer":"cus_123","subscription":"sub_abc","metadata":{"user_id":%q}}`,
		userID.String(),
	)
	body, header := buildStripeWebhookBody(secret, "checkout.session.completed", obj)
	err := svc.HandleStripeWebhook(context.Background(), body, header)
	require.NoError(t, err)
	sub, err := repo.GetByUserID(context.Background(), userID)
	require.NoError(t, err)
	assert.Equal(t, billing.TierEchoPlus, sub.Tier)
	assert.Equal(t, billing.StoreStripe, sub.Store)
	assert.Equal(t, "cus_123", sub.StoreCustomerID)
	assert.Equal(t, "sub_abc", sub.StoreSubscriptionID)
}

func TestHandleStripeWebhook_invalidSignature(t *testing.T) {
	repo := newFakeRepo()
	svc := billing.New(billing.Config{Repository: repo, StripeWebhookSecret: "real_secret"})
	body := []byte(`{"type":"checkout.session.completed","data":{"object":{}}}`)
	err := svc.HandleStripeWebhook(context.Background(), body, "t=1,v1=badsig")
	require.Error(t, err)
	assert.True(t, errors.Is(err, billing.ErrInvalidSignature))
}

func TestHandleStripeWebhook_subscriptionDeleted(t *testing.T) {
	repo := newFakeRepo()
	userID := uuid.New()
	_, _ = repo.Upsert(context.Background(), billing.Subscription{
		UserID:              userID,
		Tier:                billing.TierEchoPlus,
		Status:              billing.StatusActive,
		Store:               billing.StoreStripe,
		StoreCustomerID:     "cus_del",
		StoreSubscriptionID: "sub_del",
	})
	secret := "whsec_del"
	svc := billing.New(billing.Config{Repository: repo, StripeWebhookSecret: secret})
	periodEnd := time.Now().Add(30 * 24 * time.Hour).Unix()
	obj := fmt.Sprintf(
		`{"id":"sub_del","customer":"cus_del","status":"canceled","current_period_end":%d,"canceled_at":null}`,
		periodEnd,
	)
	body, header := buildStripeWebhookBody(secret, "customer.subscription.deleted", obj)
	err := svc.HandleStripeWebhook(context.Background(), body, header)
	require.NoError(t, err)
	sub, err := repo.GetByUserID(context.Background(), userID)
	require.NoError(t, err)
	assert.Equal(t, billing.TierFree, sub.Tier)
	assert.Equal(t, billing.StatusCanceled, sub.Status)
}

func TestHandleStripeWebhook_unknownEvent(t *testing.T) {
	repo := newFakeRepo()
	secret := "whsec_x"
	svc := billing.New(billing.Config{Repository: repo, StripeWebhookSecret: secret})
	body, header := buildStripeWebhookBody(secret, "payment_intent.created", `{"id":"pi_123"}`)
	require.NoError(t, svc.HandleStripeWebhook(context.Background(), body, header))
}

// ─── Apple notification tests ─────────────────────────────────────────────────

func TestHandleAppleNotification_subscribed(t *testing.T) {
	repo := newFakeRepo()
	svc := makeService(repo)
	userID := uuid.New()
	txPayload := map[string]any{
		"originalTransactionId": "orig_123",
		"transactionId":         "tx_456",
		"appAccountToken":       userID.String(),
		"expiresDate":           time.Now().Add(30 * 24 * time.Hour).UnixMilli(),
	}
	txJWS := fakeJWS(txPayload)
	dataPayload := map[string]any{
		"bundleId":              "app.echo.client",
		"signedTransactionInfo": txJWS,
		"signedRenewalInfo":     txJWS,
	}
	notifPayload := map[string]any{
		"notificationType": "SUBSCRIBED",
		"data":             json.RawMessage(mustJSON(dataPayload)),
	}
	outerJWS := fakeJWS(notifPayload)
	rawBody, _ := json.Marshal(map[string]string{"signedPayload": outerJWS})
	err := svc.HandleAppleNotification(context.Background(), rawBody)
	require.NoError(t, err)
	sub, err := repo.GetByUserID(context.Background(), userID)
	require.NoError(t, err)
	assert.Equal(t, billing.TierEchoPlus, sub.Tier)
	assert.Equal(t, billing.StatusActive, sub.Status)
	assert.Equal(t, billing.StoreApple, sub.Store)
	assert.Equal(t, "orig_123", sub.StoreSubscriptionID)
}

func TestHandleAppleNotification_expired(t *testing.T) {
	repo := newFakeRepo()
	svc := makeService(repo)
	userID := uuid.New()
	_, _ = repo.Upsert(context.Background(), billing.Subscription{
		UserID:              userID,
		Tier:                billing.TierEchoPlus,
		Status:              billing.StatusActive,
		Store:               billing.StoreApple,
		StoreSubscriptionID: "orig_exp",
	})
	txPayload := map[string]any{
		"originalTransactionId": "orig_exp",
		"transactionId":         "tx_exp",
		"appAccountToken":       userID.String(),
		"expiresDate":           time.Now().Add(-1 * time.Hour).UnixMilli(),
	}
	txJWS := fakeJWS(txPayload)
	dataPayload := map[string]any{
		"bundleId":              "app.echo.client",
		"signedTransactionInfo": txJWS,
		"signedRenewalInfo":     txJWS,
	}
	notifPayload := map[string]any{
		"notificationType": "EXPIRED",
		"data":             json.RawMessage(mustJSON(dataPayload)),
	}
	outerJWS := fakeJWS(notifPayload)
	rawBody, _ := json.Marshal(map[string]string{"signedPayload": outerJWS})
	err := svc.HandleAppleNotification(context.Background(), rawBody)
	require.NoError(t, err)
	sub, err := repo.GetByUserID(context.Background(), userID)
	require.NoError(t, err)
	assert.Equal(t, billing.TierFree, sub.Tier)
	assert.Equal(t, billing.StatusExpired, sub.Status)
}

// ─── Google notification tests ────────────────────────────────────────────────

func TestAcknowledgeGooglePurchase(t *testing.T) {
	repo := newFakeRepo()
	svc := makeService(repo)
	userID := uuid.New()
	err := svc.AcknowledgeGooglePurchase(context.Background(), userID, "purchase_token_xyz", "echo_plus_monthly")
	require.NoError(t, err)
	sub, err := repo.GetByUserID(context.Background(), userID)
	require.NoError(t, err)
	assert.Equal(t, billing.TierEchoPlus, sub.Tier)
	assert.Equal(t, billing.StoreGoogle, sub.Store)
	assert.Equal(t, "purchase_token_xyz", sub.StoreSubscriptionID)
}

func TestHandleGoogleNotification_purchased(t *testing.T) {
	repo := newFakeRepo()
	svc := makeService(repo)
	userID := uuid.New()
	require.NoError(t, svc.AcknowledgeGooglePurchase(context.Background(), userID, "ptok_xyz", "echo_plus_monthly"))
	inner := mustJSON(map[string]any{
		"packageName": "app.echo.client",
		"subscriptionNotification": map[string]any{
			"version":          "1.0",
			"notificationType": 4,
			"purchaseToken":    "ptok_xyz",
			"subscriptionId":   "echo_plus_monthly",
		},
		"eventTimeMillis": "1717488000000",
	})
	data := base64.StdEncoding.EncodeToString(inner)
	rawBody, _ := json.Marshal(map[string]any{
		"message":      map[string]any{"data": data, "messageId": "msg_1"},
		"subscription": "projects/echo/subscriptions/play-billing",
	})
	err := svc.HandleGoogleNotification(context.Background(), rawBody)
	require.NoError(t, err)
	sub, err := repo.GetByUserID(context.Background(), userID)
	require.NoError(t, err)
	assert.Equal(t, billing.TierEchoPlus, sub.Tier)
	assert.Equal(t, billing.StatusActive, sub.Status)
}
