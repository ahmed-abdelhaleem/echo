package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"
)

// KratosCookieName is the name of the cookie that holds the Kratos session
// token. Kratos uses this name out of the box; if you change it in
// `kratos.yml`, update this constant.
const KratosCookieName = "ory_kratos_session"

// KratosClient wraps the bits of the Kratos API the Go backend needs.
//
// Two URLs are configured separately because Kratos exposes two listeners:
// the public API (whoami, self-service flows) is reachable from the
// internet; the admin API (identity CRUD) is internal-only.
type KratosClient struct {
	publicURL string
	adminURL  string
	http      *http.Client
}

// NewKratosClient constructs a client. `publicURL` is e.g.
// `http://localhost:4433`, `adminURL` is e.g. `http://localhost:4434`. The
// HTTP client falls back to a sensible default if nil.
func NewKratosClient(publicURL, adminURL string, hc *http.Client) *KratosClient {
	if hc == nil {
		hc = &http.Client{Timeout: 5 * time.Second}
	}
	return &KratosClient{publicURL: publicURL, adminURL: adminURL, http: hc}
}

// ErrSessionNotActive is returned by [Whoami] when Kratos accepted the
// cookie but flagged the session as inactive (e.g. expired, signed out).
var ErrSessionNotActive = errors.New("kratos: session not active")

// ErrSessionUnauthorized is returned by [Whoami] when Kratos returned 401 —
// the cookie was missing, malformed, or refers to a deleted identity.
var ErrSessionUnauthorized = errors.New("kratos: session unauthorized")

// kratosSession matches the relevant subset of the Kratos `/sessions/whoami`
// response. We intentionally read only what we need so the schema can evolve
// without churn here.
type kratosSession struct {
	ID        string         `json:"id"`
	Active    bool           `json:"active"`
	IssuedAt  time.Time      `json:"issued_at"`
	ExpiresAt time.Time      `json:"expires_at"`
	Identity  kratosIdentity `json:"identity"`
}

type kratosIdentity struct {
	ID        string               `json:"id"`
	SchemaID  string               `json:"schema_id"`
	Traits    kratosIdentityTraits `json:"traits"`
	CreatedAt time.Time            `json:"created_at"`
}

type kratosIdentityTraits struct {
	Email       string `json:"email"`
	DisplayName string `json:"display_name"`
	Birthdate   string `json:"birthdate"` // ISO date (yyyy-mm-dd)
}

// Whoami validates a Kratos session cookie and returns a domain [Session].
//
// Behaviour:
//   - cookie missing -> ErrSessionUnauthorized
//   - Kratos 401     -> ErrSessionUnauthorized
//   - Kratos 200 but session.active == false -> ErrSessionNotActive
//   - Kratos 5xx or transport error          -> wrapped error
func (c *KratosClient) Whoami(ctx context.Context, cookie string) (Session, error) {
	if cookie == "" {
		return Session{}, ErrSessionUnauthorized
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.publicURL+"/sessions/whoami", nil)
	if err != nil {
		return Session{}, fmt.Errorf("kratos: build whoami request: %w", err)
	}
	// Pass the cookie through verbatim. Kratos's API expects it in the
	// `Cookie` header (it does not accept a bearer token for browser sessions).
	req.Header.Set("Cookie", KratosCookieName+"="+cookie)

	resp, err := c.http.Do(req)
	if err != nil {
		return Session{}, fmt.Errorf("kratos: whoami transport: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	switch resp.StatusCode {
	case http.StatusOK:
		// fall through to decoding
	case http.StatusUnauthorized, http.StatusForbidden:
		return Session{}, ErrSessionUnauthorized
	default:
		return Session{}, fmt.Errorf("kratos: whoami unexpected status %d", resp.StatusCode)
	}

	var ks kratosSession
	if err := json.NewDecoder(resp.Body).Decode(&ks); err != nil {
		return Session{}, fmt.Errorf("kratos: decode whoami: %w", err)
	}
	if !ks.Active {
		return Session{}, ErrSessionNotActive
	}

	return Session{
		ID:          ks.ID,
		IdentityID:  ks.Identity.ID,
		Email:       ks.Identity.Traits.Email,
		DisplayName: ks.Identity.Traits.DisplayName,
		Birthdate:   ks.Identity.Traits.Birthdate,
		IssuedAt:    ks.IssuedAt,
		ExpiresAt:   ks.ExpiresAt,
	}, nil
}
