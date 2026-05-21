package auth_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
)

// stubKratos returns an httptest.Server whose `/sessions/whoami` responds
// according to the recipe given by the test.
func stubKratos(t *testing.T, status int, body string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/sessions/whoami", func(w http.ResponseWriter, r *http.Request) {
		// Sanity-check: the cookie must arrive.
		if !strings.Contains(r.Header.Get("Cookie"), auth.KratosCookieName+"=") {
			http.Error(w, "missing cookie", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func TestKratosClient_Whoami_HappyPath(t *testing.T) {
	t.Parallel()

	body := `{
		"id": "session-abc",
		"active": true,
		"issued_at": "2026-05-21T10:00:00Z",
		"expires_at": "2030-01-01T00:00:00Z",
		"identity": {
			"id": "identity-xyz",
			"schema_id": "default",
			"created_at": "2026-01-01T00:00:00Z",
			"traits": {
				"email": "ada@example.test",
				"display_name": "Ada",
				"birthdate": "1995-06-10"
			}
		}
	}`
	srv := stubKratos(t, http.StatusOK, body)

	client := auth.NewKratosClient(srv.URL, srv.URL, nil)
	sess, err := client.Whoami(context.Background(), "cookie-value")
	if err != nil {
		t.Fatalf("Whoami returned err: %v", err)
	}

	if sess.ID != "session-abc" {
		t.Errorf("session ID: got %q, want %q", sess.ID, "session-abc")
	}
	if sess.IdentityID != "identity-xyz" {
		t.Errorf("identity ID: got %q, want %q", sess.IdentityID, "identity-xyz")
	}
	if sess.Email != "ada@example.test" {
		t.Errorf("email: got %q", sess.Email)
	}
	if !sess.HasIdentity() {
		t.Error("HasIdentity should be true")
	}
	// IssuedAt must come from the session's `issued_at` (May), NOT the
	// identity's `created_at` (January). Anything else makes session-age
	// checks lie.
	if got, want := sess.IssuedAt.UTC().Format("2006-01"), "2026-05"; got != want {
		t.Errorf("IssuedAt: got %s, want %s (must use session.issued_at, not identity.created_at)", got, want)
	}
}

func TestKratosClient_Whoami_MissingCookie(t *testing.T) {
	t.Parallel()
	// Server should never be hit; build a client with an unreachable URL
	// just to ensure no transport happens.
	client := auth.NewKratosClient("http://127.0.0.1:0", "http://127.0.0.1:0", nil)

	_, err := client.Whoami(context.Background(), "")
	if !errors.Is(err, auth.ErrSessionUnauthorized) {
		t.Fatalf("expected ErrSessionUnauthorized, got %v", err)
	}
}

func TestKratosClient_Whoami_Inactive(t *testing.T) {
	t.Parallel()
	body := `{"id":"s","active":false,"expires_at":"2030-01-01T00:00:00Z","identity":{"id":"i","traits":{}}}`
	srv := stubKratos(t, http.StatusOK, body)

	client := auth.NewKratosClient(srv.URL, srv.URL, nil)
	_, err := client.Whoami(context.Background(), "cookie")
	if !errors.Is(err, auth.ErrSessionNotActive) {
		t.Fatalf("expected ErrSessionNotActive, got %v", err)
	}
}

func TestKratosClient_Whoami_Unauthorized(t *testing.T) {
	t.Parallel()
	srv := stubKratos(t, http.StatusUnauthorized, `{"error":"unauthorized"}`)

	client := auth.NewKratosClient(srv.URL, srv.URL, nil)
	_, err := client.Whoami(context.Background(), "cookie")
	if !errors.Is(err, auth.ErrSessionUnauthorized) {
		t.Fatalf("expected ErrSessionUnauthorized, got %v", err)
	}
}

func TestKratosClient_Whoami_5xx(t *testing.T) {
	t.Parallel()
	srv := stubKratos(t, http.StatusInternalServerError, `{"error":"boom"}`)

	client := auth.NewKratosClient(srv.URL, srv.URL, nil)
	_, err := client.Whoami(context.Background(), "cookie")
	if err == nil {
		t.Fatal("expected an error for 5xx")
	}
	// Must NOT be classified as Unauthorized or NotActive — those map to 401.
	if errors.Is(err, auth.ErrSessionUnauthorized) || errors.Is(err, auth.ErrSessionNotActive) {
		t.Errorf("5xx must not be classified as session error; got %v", err)
	}
}
