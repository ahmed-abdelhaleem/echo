package http

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestWrapWithKratosProxy_forwardsToKratos(t *testing.T) {
	t.Parallel()

	kratos := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "/self-service/registration/api", r.URL.Path)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"id":"flow-1"}`))
	}))
	t.Cleanup(kratos.Close)

	next := http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Fatal("next handler should not run")
	})
	h := WrapWithKratosProxy(kratos.URL, next)

	req := httptest.NewRequest(http.MethodGet, "/auth/kratos/self-service/registration/api", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code)
	body, err := io.ReadAll(rec.Body)
	require.NoError(t, err)
	require.Contains(t, string(body), "flow-1")
}

func TestWrapWithKratosProxy_stripsUpstreamCORSHeaders(t *testing.T) {
	t.Parallel()

	kratos := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "http://localhost:8082")
		w.Header().Set("Access-Control-Allow-Credentials", "true")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`ok`))
	}))
	t.Cleanup(kratos.Close)

	h := WrapWithKratosProxy(kratos.URL, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Fatal("next handler should not run")
	}))

	req := httptest.NewRequest(http.MethodGet, "/auth/kratos/self-service/login/api", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code)
	require.Empty(t, rec.Header().Get("Access-Control-Allow-Origin"))
	require.Empty(t, rec.Header().Get("Access-Control-Allow-Credentials"))
}

func TestWrapWithKratosProxy_passesThroughOtherPaths(t *testing.T) {
	t.Parallel()

	var hit bool
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hit = true
		w.WriteHeader(http.StatusNoContent)
	})
	h := WrapWithKratosProxy("http://localhost:4433", next)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	require.True(t, hit)
	require.Equal(t, http.StatusNoContent, rec.Code)
}
