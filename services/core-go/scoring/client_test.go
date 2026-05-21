package scoring_test

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/scoring"
)

func newSilentLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestHTTPClient_Score_HappyPath(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/score" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		var got scoring.ScoreRequest
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		if got.PlaythroughID != "p1" || len(got.Weights) != 2 {
			t.Errorf("unexpected request body: %+v", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(scoring.ScoreResponse{
			PlaythroughID:  "p1",
			ScoringVersion: "rule-v1",
			Vector: map[string]float64{
				"OCEAN-O": 0.5,
				"OCEAN-C": 0.0,
			},
			UnknownDimensions: []string{},
		})
	}))
	defer server.Close()

	client := scoring.NewHTTPClient(server.URL, newSilentLogger())
	resp, err := client.Score(context.Background(), scoring.ScoreRequest{
		PlaythroughID: "p1",
		Weights: []scoring.TraitWeight{
			{Dimension: "OCEAN-O", Delta: 0.3},
			{Dimension: "OCEAN-O", Delta: 0.2},
		},
	})
	if err != nil {
		t.Fatalf("Score: %v", err)
	}
	if resp.ScoringVersion != "rule-v1" {
		t.Errorf("scoring_version: %q", resp.ScoringVersion)
	}
	if resp.Vector["OCEAN-O"] != 0.5 {
		t.Errorf("vector: %+v", resp.Vector)
	}
}

func TestHTTPClient_Score_5xxIsTransport(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer server.Close()

	client := scoring.NewHTTPClient(server.URL, newSilentLogger())
	_, err := client.Score(context.Background(), scoring.ScoreRequest{PlaythroughID: "p1"})
	if !errors.Is(err, scoring.ErrTransport) {
		t.Errorf("want ErrTransport, got %v", err)
	}
}

func TestHTTPClient_Score_4xxIsNotTransport(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "bad payload", http.StatusBadRequest)
	}))
	defer server.Close()

	client := scoring.NewHTTPClient(server.URL, newSilentLogger())
	_, err := client.Score(context.Background(), scoring.ScoreRequest{PlaythroughID: "p1"})
	if err == nil {
		t.Fatal("want error, got nil")
	}
	if errors.Is(err, scoring.ErrTransport) {
		t.Errorf("4xx should not be ErrTransport; got %v", err)
	}
	if !strings.Contains(err.Error(), "status 400") {
		t.Errorf("error should name the status: %v", err)
	}
}

func TestHTTPClient_Score_MalformedBodyIsInvalidResponse(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte("not json"))
	}))
	defer server.Close()

	client := scoring.NewHTTPClient(server.URL, newSilentLogger())
	_, err := client.Score(context.Background(), scoring.ScoreRequest{PlaythroughID: "p1"})
	if !errors.Is(err, scoring.ErrInvalidResponse) {
		t.Errorf("want ErrInvalidResponse, got %v", err)
	}
}

func TestHTTPClient_Score_MissingVectorIsInvalidResponse(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"playthrough_id":"p1","scoring_version":"rule-v1"}`))
	}))
	defer server.Close()

	client := scoring.NewHTTPClient(server.URL, newSilentLogger())
	_, err := client.Score(context.Background(), scoring.ScoreRequest{PlaythroughID: "p1"})
	if !errors.Is(err, scoring.ErrInvalidResponse) {
		t.Errorf("want ErrInvalidResponse, got %v", err)
	}
}

func TestHTTPClient_Score_TransportFailureIsErrTransport(t *testing.T) {
	t.Parallel()

	// Closed server -> connection refused.
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	server.Close()

	client := scoring.NewHTTPClient(server.URL, newSilentLogger())
	_, err := client.Score(context.Background(), scoring.ScoreRequest{PlaythroughID: "p1"})
	if !errors.Is(err, scoring.ErrTransport) {
		t.Errorf("want ErrTransport, got %v", err)
	}
}
