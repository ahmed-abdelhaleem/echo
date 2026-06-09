package auth_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/google/uuid"
)

// fakeUsers is a minimal in-memory UsersRepository for hook tests.
type fakeUsers struct {
	mu          sync.Mutex
	ensureCalls []ensureCall
	deletedIDs  []uuid.UUID
	ensureErr   error
	softDelErr  error
	provisioned map[uuid.UUID]auth.User
	getOverride func(uuid.UUID) (auth.User, error)
}

type ensureCall struct {
	IdentityID uuid.UUID
	Band       auth.AgeBand
}

func newFakeUsers() *fakeUsers {
	return &fakeUsers{provisioned: make(map[uuid.UUID]auth.User)}
}

func (f *fakeUsers) GetByKratosID(_ context.Context, id uuid.UUID) (auth.User, error) {
	if f.getOverride != nil {
		return f.getOverride(id)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if u, ok := f.provisioned[id]; ok {
		return u, nil
	}
	return auth.User{}, auth.ErrUserNotFound
}

func (f *fakeUsers) GetByID(_ context.Context, id uuid.UUID) (auth.User, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, u := range f.provisioned {
		if u.ID == id {
			return u, nil
		}
	}
	return auth.User{}, auth.ErrUserNotFound
}

func (f *fakeUsers) EnsureFromSession(_ context.Context, _ auth.Session, _ time.Time) (auth.User, error) {
	return auth.User{}, nil
}

func (f *fakeUsers) EnsureForKratosIdentity(_ context.Context, id uuid.UUID, band auth.AgeBand, now time.Time) (auth.User, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ensureCalls = append(f.ensureCalls, ensureCall{IdentityID: id, Band: band})
	if f.ensureErr != nil {
		return auth.User{}, f.ensureErr
	}
	u := auth.User{
		ID:               uuid.New(),
		KratosIdentityID: id,
		AgeBand:          band,
		CreatedAt:        now,
	}
	f.provisioned[id] = u
	return u, nil
}

func (f *fakeUsers) SoftDeleteByKratosID(_ context.Context, id uuid.UUID, _ time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deletedIDs = append(f.deletedIDs, id)
	if f.softDelErr != nil {
		return f.softDelErr
	}
	delete(f.provisioned, id)
	return nil
}

// adminKratos returns an httptest server that emulates Kratos's admin API
// for the DeleteIdentity call. The `deleted` slice is captured by reference
// so tests can assert which ids were torn down.
func adminKratos(t *testing.T, deleted *[]string, status int) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/admin/identities/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete {
			http.Error(w, "wrong method", http.StatusMethodNotAllowed)
			return
		}
		id := r.URL.Path[len("/admin/identities/"):]
		*deleted = append(*deleted, id)
		w.WriteHeader(status)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

// hookCfgWithKratos constructs a HookConfig pointed at the given admin URL.
func hookCfgWithKratos(adminURL, secret string, users auth.UsersRepository) auth.HookConfig {
	return auth.HookConfig{
		Secret: secret,
		Users:  users,
		Kratos: auth.NewKratosClient(adminURL, adminURL, nil),
		Now:    fixedNow,
	}
}

// --- BeforeRegistrationHandler tests -------------------------------------

func TestBeforeHook_AdultAllowed(t *testing.T) {
	t.Parallel()
	users := newFakeUsers()
	cfg := hookCfgWithKratos("http://unused", "", users)

	body := `{"traits":{"birthdate":"1990-01-15"}}`
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/before-registration",
		bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()

	auth.BeforeRegistrationHandler(cfg)(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
}

func TestBeforeHook_YouthAllowed(t *testing.T) {
	t.Parallel()
	users := newFakeUsers()
	cfg := hookCfgWithKratos("http://unused", "", users)

	body := `{"traits":{"birthdate":"2012-01-15"}}`
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/before-registration",
		bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()

	auth.BeforeRegistrationHandler(cfg)(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
}

func TestBeforeHook_Under13Rejected(t *testing.T) {
	t.Parallel()
	users := newFakeUsers()
	cfg := hookCfgWithKratos("http://unused", "", users)

	body := `{"traits":{"birthdate":"2018-01-15"}}`
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/before-registration",
		bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()

	auth.BeforeRegistrationHandler(cfg)(rec, req)

	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status: got %d, want 422; body=%s", rec.Code, rec.Body.String())
	}
	// Body must include a `messages` field with a non-empty text — the
	// Kratos client surfaces this as the rejection reason.
	var parsed struct {
		Messages []struct {
			InstancePtr string `json:"instance_ptr"`
			Messages    []struct {
				Text string `json:"text"`
			} `json:"messages"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatalf("unmarshal: %v; body=%s", err, rec.Body.String())
	}
	if len(parsed.Messages) == 0 || len(parsed.Messages[0].Messages) == 0 ||
		parsed.Messages[0].Messages[0].Text == "" {
		t.Fatalf("expected a non-empty text message; body=%s", rec.Body.String())
	}
	if parsed.Messages[0].InstancePtr != "#/traits/birthdate" {
		t.Errorf("instance_ptr: got %q, want %q",
			parsed.Messages[0].InstancePtr, "#/traits/birthdate")
	}
}

func TestBeforeHook_InvalidBirthdateRejected(t *testing.T) {
	t.Parallel()
	users := newFakeUsers()
	cfg := hookCfgWithKratos("http://unused", "", users)

	body := `{"traits":{"birthdate":"not-a-date"}}`
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/before-registration",
		bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()

	auth.BeforeRegistrationHandler(cfg)(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status: got %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

func TestBeforeHook_SecretRequired(t *testing.T) {
	t.Parallel()
	users := newFakeUsers()
	cfg := hookCfgWithKratos("http://unused", "the-secret", users)

	body := `{"traits":{"birthdate":"1990-01-15"}}`
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/before-registration",
		bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()

	auth.BeforeRegistrationHandler(cfg)(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status: got %d, want 401 when secret missing; body=%s", rec.Code, rec.Body.String())
	}

	// Same request WITH the correct secret should pass.
	req2 := httptest.NewRequest(http.MethodPost, "/auth/hooks/before-registration",
		bytes.NewReader([]byte(body)))
	req2.Header.Set(auth.HookSecretHeader, "the-secret")
	rec2 := httptest.NewRecorder()
	auth.BeforeRegistrationHandler(cfg)(rec2, req2)

	if rec2.Code != http.StatusOK {
		t.Fatalf("status with secret: got %d, want 200; body=%s", rec2.Code, rec2.Body.String())
	}
}

func TestBeforeHook_BadJSONRejected(t *testing.T) {
	t.Parallel()
	cfg := hookCfgWithKratos("http://unused", "", newFakeUsers())
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/before-registration",
		bytes.NewReader([]byte("not-json")))
	rec := httptest.NewRecorder()
	auth.BeforeRegistrationHandler(cfg)(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status: got %d, want 400", rec.Code)
	}
}

// --- AfterRegistrationHandler tests --------------------------------------

func TestAfterHook_AdultProvisions(t *testing.T) {
	t.Parallel()
	var deleted []string
	srv := adminKratos(t, &deleted, http.StatusNoContent)

	users := newFakeUsers()
	cfg := hookCfgWithKratos(srv.URL, "", users)

	id := uuid.New()
	body := `{"identity":{"id":"` + id.String() + `","traits":{"birthdate":"1990-01-15"}}}`
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/after-registration",
		bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()
	auth.AfterRegistrationHandler(cfg)(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if len(users.ensureCalls) != 1 {
		t.Fatalf("ensure calls: got %d, want 1", len(users.ensureCalls))
	}
	call := users.ensureCalls[0]
	if call.IdentityID != id {
		t.Errorf("identity: got %v, want %v", call.IdentityID, id)
	}
	if call.Band != auth.AgeBandAdult {
		t.Errorf("band: got %q, want %q", call.Band, auth.AgeBandAdult)
	}
	if len(deleted) != 0 {
		t.Errorf("expected no delete calls for an allowed identity; got %v", deleted)
	}
}

func TestAfterHook_YouthProvisions(t *testing.T) {
	t.Parallel()
	var deleted []string
	srv := adminKratos(t, &deleted, http.StatusNoContent)

	users := newFakeUsers()
	cfg := hookCfgWithKratos(srv.URL, "", users)

	id := uuid.New()
	body := `{"identity":{"id":"` + id.String() + `","traits":{"birthdate":"2012-01-15"}}}`
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/after-registration",
		bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()
	auth.AfterRegistrationHandler(cfg)(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if len(users.ensureCalls) != 1 || users.ensureCalls[0].Band != auth.AgeBandYouth {
		t.Errorf("expected one youth ensure call, got %#v", users.ensureCalls)
	}
}

// T-CORE-021 acceptance: under-13 must be torn down at the boundary even
// if the before-hook failed to fire. The after-hook re-runs the gate and
// uses the Kratos admin API to delete the freshly-created identity.
func TestAfterHook_Under13RollsBackIdentity(t *testing.T) {
	t.Parallel()
	var deleted []string
	srv := adminKratos(t, &deleted, http.StatusNoContent)

	users := newFakeUsers()
	cfg := hookCfgWithKratos(srv.URL, "", users)

	id := uuid.New()
	body := `{"identity":{"id":"` + id.String() + `","traits":{"birthdate":"2018-01-15"}}}`
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/after-registration",
		bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()
	auth.AfterRegistrationHandler(cfg)(rec, req)

	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status: got %d, want 422; body=%s", rec.Code, rec.Body.String())
	}
	if len(users.ensureCalls) != 0 {
		t.Errorf("expected no provision calls for under-13; got %v", users.ensureCalls)
	}
	if len(deleted) != 1 || deleted[0] != id.String() {
		t.Errorf("expected admin delete on identity %s, got %v", id, deleted)
	}
}

func TestAfterHook_RollbackToleratesAlreadyGone(t *testing.T) {
	t.Parallel()
	var deleted []string
	// Kratos returns 404 — already gone. Hook should still respond 422
	// without surfacing the 404 to the caller.
	srv := adminKratos(t, &deleted, http.StatusNotFound)

	users := newFakeUsers()
	cfg := hookCfgWithKratos(srv.URL, "", users)

	id := uuid.New()
	body := `{"identity":{"id":"` + id.String() + `","traits":{"birthdate":"2018-01-15"}}}`
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/after-registration",
		bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()
	auth.AfterRegistrationHandler(cfg)(rec, req)

	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status: got %d, want 422; body=%s", rec.Code, rec.Body.String())
	}
}

func TestAfterHook_InvalidIdentityID(t *testing.T) {
	t.Parallel()
	var deleted []string
	srv := adminKratos(t, &deleted, http.StatusNoContent)
	cfg := hookCfgWithKratos(srv.URL, "", newFakeUsers())

	body := `{"identity":{"id":"not-a-uuid","traits":{"birthdate":"1990-01-15"}}}`
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/after-registration",
		bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()
	auth.AfterRegistrationHandler(cfg)(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status: got %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

func TestAfterHook_NilIdentityIDSkipsProvisioning(t *testing.T) {
	t.Parallel()
	var deleted []string
	srv := adminKratos(t, &deleted, http.StatusNoContent)

	users := newFakeUsers()
	cfg := hookCfgWithKratos(srv.URL, "", users)

	body := `{"identity":{"id":"00000000-0000-0000-0000-000000000000","traits":{"birthdate":"1990-01-15"}}}`
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/after-registration",
		bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()
	auth.AfterRegistrationHandler(cfg)(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if len(users.ensureCalls) != 0 {
		t.Fatalf("expected no provisioning for nil identity id; got %d ensure calls", len(users.ensureCalls))
	}
	if len(deleted) != 0 {
		t.Fatalf("expected no admin delete for nil identity id; got %v", deleted)
	}
}

func TestAfterHook_SecretRequired(t *testing.T) {
	t.Parallel()
	var deleted []string
	srv := adminKratos(t, &deleted, http.StatusNoContent)
	cfg := hookCfgWithKratos(srv.URL, "the-secret", newFakeUsers())

	id := uuid.New()
	body := `{"identity":{"id":"` + id.String() + `","traits":{"birthdate":"1990-01-15"}}}`
	req := httptest.NewRequest(http.MethodPost, "/auth/hooks/after-registration",
		bytes.NewReader([]byte(body)))
	rec := httptest.NewRecorder()
	auth.AfterRegistrationHandler(cfg)(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status without secret: got %d, want 401", rec.Code)
	}
}

func TestAfterHook_PanicsWithoutDependencies(t *testing.T) {
	t.Parallel()
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic when Users is nil")
		}
	}()
	_ = auth.AfterRegistrationHandler(auth.HookConfig{Kratos: auth.NewKratosClient("x", "x", nil)})
}

// --- DeleteIdentity admin API tests --------------------------------------

func TestKratosClient_DeleteIdentity_HappyPath(t *testing.T) {
	t.Parallel()
	var deleted []string
	srv := adminKratos(t, &deleted, http.StatusNoContent)

	client := auth.NewKratosClient(srv.URL, srv.URL, nil)
	err := client.DeleteIdentity(context.Background(), "identity-xyz")
	if err != nil {
		t.Fatalf("DeleteIdentity: %v", err)
	}
	if len(deleted) != 1 || deleted[0] != "identity-xyz" {
		t.Errorf("deleted: got %v, want [identity-xyz]", deleted)
	}
}

func TestKratosClient_DeleteIdentity_NotFound(t *testing.T) {
	t.Parallel()
	var deleted []string
	srv := adminKratos(t, &deleted, http.StatusNotFound)

	client := auth.NewKratosClient(srv.URL, srv.URL, nil)
	err := client.DeleteIdentity(context.Background(), "identity-xyz")
	if !errors.Is(err, auth.ErrIdentityNotFound) {
		t.Errorf("expected ErrIdentityNotFound, got %v", err)
	}
}

func TestKratosClient_DeleteIdentity_5xx(t *testing.T) {
	t.Parallel()
	var deleted []string
	srv := adminKratos(t, &deleted, http.StatusInternalServerError)

	client := auth.NewKratosClient(srv.URL, srv.URL, nil)
	err := client.DeleteIdentity(context.Background(), "identity-xyz")
	if err == nil {
		t.Fatal("expected an error on 5xx")
	}
	if errors.Is(err, auth.ErrIdentityNotFound) {
		t.Errorf("5xx must not be classified as not-found; got %v", err)
	}
}

func TestKratosClient_DeleteIdentity_EmptyID(t *testing.T) {
	t.Parallel()
	client := auth.NewKratosClient("http://x", "http://x", nil)
	if err := client.DeleteIdentity(context.Background(), ""); err == nil {
		t.Error("expected an error for empty id")
	}
}

func TestKratosClient_DeleteIdentity_AdminURLRequired(t *testing.T) {
	t.Parallel()
	client := auth.NewKratosClient("http://x", "", nil)
	if err := client.DeleteIdentity(context.Background(), "id"); err == nil {
		t.Error("expected an error when admin URL is unset")
	}
}

// --- DeleteMeHandler tests -----------------------------------------------

func TestDeleteMe_HappyPath(t *testing.T) {
	t.Parallel()
	var deleted []string
	srv := adminKratos(t, &deleted, http.StatusNoContent)

	users := newFakeUsers()
	id := uuid.New()
	// Pre-provision so SoftDelete has something to do.
	_, _ = users.EnsureForKratosIdentity(context.Background(), id, auth.AgeBandAdult, fixedNow())

	cfg := auth.DeleteMeConfig{
		Users:  users,
		Kratos: auth.NewKratosClient(srv.URL, srv.URL, nil),
		Now:    fixedNow,
	}
	h := auth.DeleteMeHandler(cfg)

	req := httptest.NewRequest(http.MethodDelete, "/me", nil)
	// Inject a session into the request context, simulating what the
	// auth.Middleware does for the real handler chain.
	req = req.WithContext(injectSession(req.Context(), auth.Session{
		ID:         "session-abc",
		IdentityID: id.String(),
	}))
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status: got %d, want 204; body=%s", rec.Code, rec.Body.String())
	}
	if len(deleted) != 1 || deleted[0] != id.String() {
		t.Errorf("expected admin delete of %s, got %v", id, deleted)
	}
	if len(users.deletedIDs) != 1 || users.deletedIDs[0] != id {
		t.Errorf("expected soft delete of %s, got %v", id, users.deletedIDs)
	}
}

func TestDeleteMe_NoSession(t *testing.T) {
	t.Parallel()
	var deleted []string
	srv := adminKratos(t, &deleted, http.StatusNoContent)
	cfg := auth.DeleteMeConfig{
		Users:  newFakeUsers(),
		Kratos: auth.NewKratosClient(srv.URL, srv.URL, nil),
	}
	h := auth.DeleteMeHandler(cfg)

	req := httptest.NewRequest(http.MethodDelete, "/me", nil)
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status without session: got %d, want 500", rec.Code)
	}
}

func TestDeleteMe_InvalidIdentityID(t *testing.T) {
	t.Parallel()
	var deleted []string
	srv := adminKratos(t, &deleted, http.StatusNoContent)
	cfg := auth.DeleteMeConfig{
		Users:  newFakeUsers(),
		Kratos: auth.NewKratosClient(srv.URL, srv.URL, nil),
	}
	h := auth.DeleteMeHandler(cfg)

	req := httptest.NewRequest(http.MethodDelete, "/me", nil)
	req = req.WithContext(injectSession(req.Context(), auth.Session{
		ID:         "s",
		IdentityID: "not-a-uuid",
	}))
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status: got %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}

func TestDeleteMe_KratosAlreadyGone(t *testing.T) {
	t.Parallel()
	var deleted []string
	// 404 simulates Kratos already having deleted the identity; the
	// handler must still report success since the post-condition (no
	// identity / no auth.users row) is satisfied.
	srv := adminKratos(t, &deleted, http.StatusNotFound)

	users := newFakeUsers()
	id := uuid.New()

	cfg := auth.DeleteMeConfig{
		Users:  users,
		Kratos: auth.NewKratosClient(srv.URL, srv.URL, nil),
		Now:    fixedNow,
	}
	h := auth.DeleteMeHandler(cfg)

	req := httptest.NewRequest(http.MethodDelete, "/me", nil)
	req = req.WithContext(injectSession(req.Context(), auth.Session{
		ID:         "s",
		IdentityID: id.String(),
	}))
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status: got %d, want 204 (404-on-admin is still a delete); body=%s",
			rec.Code, rec.Body.String())
	}
}

func TestDeleteMe_PanicsWithoutDependencies(t *testing.T) {
	t.Parallel()
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic without Users")
		}
	}()
	_ = auth.DeleteMeHandler(auth.DeleteMeConfig{
		Kratos: auth.NewKratosClient("x", "x", nil),
	})
}

// injectSession attaches a Session to the context the same way
// auth.Middleware does. Implemented here (rather than exporting from the
// production code) by going through a tiny round-trip via the Middleware
// itself when Kratos returns the session.
func injectSession(ctx context.Context, sess auth.Session) context.Context {
	// We can't call auth.contextWithSession directly (unexported), so
	// stand up a one-shot httptest server that mimics Kratos's
	// /sessions/whoami responding with the supplied session, run the
	// middleware against a fake request to capture the resulting
	// context, and return that.
	body, err := json.Marshal(map[string]any{
		"id":         sess.ID,
		"active":     true,
		"issued_at":  sess.IssuedAt,
		"expires_at": sess.ExpiresAt,
		"identity": map[string]any{
			"id": sess.IdentityID,
			"traits": map[string]any{
				"email":        sess.Email,
				"display_name": sess.DisplayName,
				"birthdate":    sess.Birthdate,
			},
		},
	})
	if err != nil {
		panic(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.Copy(w, bytes.NewReader(body))
	}))
	// Don't Close srv; tests are short-lived. (httptest finalizers run
	// at exit; in CI the few extra fds are inconsequential.)

	client := auth.NewKratosClient(srv.URL, srv.URL, nil)

	var captured context.Context
	mw := auth.Middleware(client, nil)
	handler := mw(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		captured = r.Context()
	}))
	handler.ServeHTTP(httptest.NewRecorder(), wrapReqWithCookie(ctx))
	if captured == nil {
		panic("middleware did not attach a session — wiring drift")
	}
	return captured
}

// wrapReqWithCookie returns an http.Request carrying the Kratos cookie
// the middleware looks for.
func wrapReqWithCookie(ctx context.Context) *http.Request {
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req = req.WithContext(ctx)
	req.AddCookie(&http.Cookie{Name: auth.KratosCookieName, Value: "v"})
	return req
}
