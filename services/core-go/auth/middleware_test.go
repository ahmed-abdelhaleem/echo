package auth_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
)

// protectedHandler is the downstream handler used by middleware tests. It
// records the session attached by the middleware so the test can assert on it.
func protectedHandler(t *testing.T, wantIdentityID string) http.Handler {
	t.Helper()
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			t.Error("expected session in context")
			http.Error(w, "no session", http.StatusInternalServerError)
			return
		}
		if sess.IdentityID != wantIdentityID {
			t.Errorf("identity ID: got %q, want %q", sess.IdentityID, wantIdentityID)
		}
		w.WriteHeader(http.StatusOK)
	})
}

func TestMiddleware_AcceptsActiveSession(t *testing.T) {
	t.Parallel()

	kratos := stubKratos(t, http.StatusOK, `{
		"id": "s1",
		"active": true,
		"expires_at": "2030-01-01T00:00:00Z",
		"identity": {
			"id": "user-123",
			"traits": {"email": "a@b.test", "display_name": "A", "birthdate": "1995-06-10"}
		}
	}`)
	client := auth.NewKratosClient(kratos.URL, kratos.URL, nil)

	mw := auth.Middleware(client, nil)
	srv := httptest.NewServer(mw(protectedHandler(t, "user-123")))
	t.Cleanup(srv.Close)

	req, err := http.NewRequest(http.MethodGet, srv.URL, nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	req.AddCookie(&http.Cookie{Name: auth.KratosCookieName, Value: "session-token"})

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })

	if resp.StatusCode != http.StatusOK {
		t.Errorf("status: got %d, want 200", resp.StatusCode)
	}
}

func TestMiddleware_RejectsMissingCookie(t *testing.T) {
	t.Parallel()
	// The Kratos endpoint should never be hit when the cookie is missing.
	kratos := stubKratos(t, http.StatusInternalServerError, `{"error":"should not be called"}`)
	client := auth.NewKratosClient(kratos.URL, kratos.URL, nil)

	mw := auth.Middleware(client, nil)
	srv := httptest.NewServer(mw(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		t.Error("downstream handler should not run when cookie is missing")
	})))
	t.Cleanup(srv.Close)

	resp, err := http.Get(srv.URL)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })

	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status: got %d, want 401", resp.StatusCode)
	}
}

func TestMiddleware_RejectsInactiveSession(t *testing.T) {
	t.Parallel()
	kratos := stubKratos(t, http.StatusOK,
		`{"id":"s","active":false,"expires_at":"2030-01-01T00:00:00Z","identity":{"id":"u","traits":{}}}`)
	client := auth.NewKratosClient(kratos.URL, kratos.URL, nil)

	mw := auth.Middleware(client, nil)
	srv := httptest.NewServer(mw(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		t.Error("downstream handler should not run for inactive sessions")
	})))
	t.Cleanup(srv.Close)

	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	req.AddCookie(&http.Cookie{Name: auth.KratosCookieName, Value: "x"})
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })

	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status: got %d, want 401", resp.StatusCode)
	}
}

func TestMiddleware_Returns502WhenKratosUnreachable(t *testing.T) {
	t.Parallel()

	// Point the client at a port nothing is listening on so the request
	// fails at transport.
	client := auth.NewKratosClient("http://127.0.0.1:1", "http://127.0.0.1:1", nil)

	mw := auth.Middleware(client, nil)
	srv := httptest.NewServer(mw(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		t.Error("downstream handler should not run when Kratos is unreachable")
	})))
	t.Cleanup(srv.Close)

	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	req.AddCookie(&http.Cookie{Name: auth.KratosCookieName, Value: "x"})
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })

	if resp.StatusCode != http.StatusBadGateway {
		t.Errorf("status: got %d, want 502", resp.StatusCode)
	}
}

func TestSessionFromContext_NoSessionAttached(t *testing.T) {
	t.Parallel()
	_, ok := auth.SessionFromContext(context.Background())
	if ok {
		t.Error("SessionFromContext on a bare context should return ok=false")
	}
}
