package scoring

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"
)

// Client is the abstract scoring surface. The playthrough service depends
// on this interface, not on the concrete HTTPClient, so tests can inject
// a deterministic in-process fake.
type Client interface {
	Score(ctx context.Context, req ScoreRequest) (ScoreResponse, error)
}

// HTTPClient is the production Client implementation. It speaks JSON over
// HTTP to the ml-py /score endpoint.
//
// Configuration:
//
//   - BaseURL points at the ml-py service root (no trailing slash).
//   - HTTP is shared so the underlying transport's connection pool is
//     reused across calls.
//   - Timeout is enforced per-call via context, not by the http.Client
//     directly. This lets a higher layer (sweeper, request handler) hold
//     a single, consistent deadline budget.
type HTTPClient struct {
	BaseURL string
	HTTP    *http.Client
	Logger  *slog.Logger
}

// NewHTTPClient builds an HTTPClient with sensible defaults. baseURL is
// usually loaded from configuration (ML_PY_BASE_URL).
func NewHTTPClient(baseURL string, logger *slog.Logger) *HTTPClient {
	if logger == nil {
		logger = slog.Default()
	}
	return &HTTPClient{
		BaseURL: baseURL,
		HTTP: &http.Client{
			// Per-call ceiling so a hung ml-py never wedges the caller.
			// The caller's context.Context is the real deadline; this
			// is just a backstop.
			Timeout: 10 * time.Second,
		},
		Logger: logger,
	}
}

// Score posts the request to ml-py and unmarshals the response. Network
// or 5xx errors return ErrTransport; malformed 2xx bodies return
// ErrInvalidResponse; 4xx bodies are returned wrapped in their status
// code as a plain error (these are programmer bugs, not transient
// conditions, and should not be retried).
func (c *HTTPClient) Score(ctx context.Context, req ScoreRequest) (ScoreResponse, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return ScoreResponse{}, fmt.Errorf("scoring: marshal request: %w", err)
	}

	url := c.BaseURL + "/score"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return ScoreResponse{}, fmt.Errorf("scoring: build request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")

	resp, err := c.HTTP.Do(httpReq)
	if err != nil {
		c.Logger.Warn("scoring transport failed",
			"err", err.Error(), "url", url,
			"playthrough_id", req.PlaythroughID)
		return ScoreResponse{}, fmt.Errorf("%w: %v", ErrTransport, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 500 {
		// 5xx is transient; reuse ErrTransport so the playthrough service
		// defers retry rather than marking the playthrough completed.
		return ScoreResponse{}, fmt.Errorf("%w: status %d", ErrTransport, resp.StatusCode)
	}
	if resp.StatusCode >= 400 {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return ScoreResponse{}, fmt.Errorf("scoring: status %d: %s", resp.StatusCode, string(respBody))
	}

	var out ScoreResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return ScoreResponse{}, fmt.Errorf("%w: %v", ErrInvalidResponse, err)
	}
	if out.Vector == nil {
		return ScoreResponse{}, fmt.Errorf("%w: missing vector", ErrInvalidResponse)
	}
	return out, nil
}

// Compile-time guard that HTTPClient satisfies Client.
var _ Client = (*HTTPClient)(nil)
