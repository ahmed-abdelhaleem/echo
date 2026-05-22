package grpc

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/grpc/echopb"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

// stubServer is a minimal TraitScoringServiceServer that records the
// last request it saw and returns a configurable response or status.
type stubServer struct {
	echopb.UnimplementedTraitScoringServiceServer
	gotReq *echopb.ScoreRequest
	resp   *echopb.ScoreResponse
	err    error
}

func (s *stubServer) Score(_ context.Context, in *echopb.ScoreRequest) (*echopb.ScoreResponse, error) {
	s.gotReq = in
	if s.err != nil {
		return nil, s.err
	}
	return s.resp, nil
}

func newClientForStub(t *testing.T, stub *stubServer) *MLClient {
	t.Helper()

	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen: %v", err)
	}
	srv := grpc.NewServer()
	echopb.RegisterTraitScoringServiceServer(srv, stub)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(func() { srv.Stop() })

	// Tiny sleep so the server registers the listener before we dial.
	time.Sleep(20 * time.Millisecond)

	conn, err := grpc.NewClient(lis.Addr().String(),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("grpc.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	return &MLClient{conn: conn, scorer: echopb.NewTraitScoringServiceClient(conn)}
}

func TestMLClient_Score_HappyPath_TranslatesPayload(t *testing.T) {
	stub := &stubServer{
		resp: &echopb.ScoreResponse{
			BigFive:    []float64{0.1, 0, 0, 0, 0},
			Schwartz:   make([]float64, 10),
			Attachment: []float64{0.2, 0, 0},
		},
	}
	client := newClientForStub(t, stub)

	got, err := client.Score(context.Background(), playthrough.TraitScoringInput{
		PlaythroughID: "pt-1",
		SeasonID:      "season-001",
		SeasonVersion: 7,
		Events: []playthrough.ScoredChoice{
			{VignetteID: "vignette-001", ChoiceID: "choice-1"},
			{VignetteID: "vignette-002", ChoiceID: "choice-3"},
		},
	})
	if err != nil {
		t.Fatalf("Score: %v", err)
	}
	if stub.gotReq == nil {
		t.Fatal("stub did not receive a request")
	}
	if stub.gotReq.PlaythroughId != "pt-1" {
		t.Errorf("playthrough_id: want pt-1, got %q", stub.gotReq.PlaythroughId)
	}
	if stub.gotReq.SeasonId != "season-001" {
		t.Errorf("season_id: want season-001, got %q", stub.gotReq.SeasonId)
	}
	if stub.gotReq.SeasonVersion != 7 {
		t.Errorf("season_version: want 7, got %d", stub.gotReq.SeasonVersion)
	}
	if len(stub.gotReq.Events) != 2 {
		t.Fatalf("event count: want 2, got %d", len(stub.gotReq.Events))
	}
	if len(got.BigFive) != 5 || len(got.Schwartz) != 10 || len(got.Attachment) != 3 {
		t.Errorf("vector shape: big_five=%d schwartz=%d attachment=%d",
			len(got.BigFive), len(got.Schwartz), len(got.Attachment))
	}
}

func TestMLClient_Score_NotFoundMapsToErrSeasonNotFound(t *testing.T) {
	stub := &stubServer{err: status.Error(codes.NotFound, "no such season")}
	client := newClientForStub(t, stub)

	_, err := client.Score(context.Background(), playthrough.TraitScoringInput{
		PlaythroughID: "pt-1", SeasonID: "season-missing", SeasonVersion: 1,
	})
	if !errors.Is(err, ErrSeasonNotFound) {
		t.Errorf("want ErrSeasonNotFound, got %v", err)
	}
}

func TestMLClient_Score_InvalidArgumentMapsToErrInvalidEvent(t *testing.T) {
	stub := &stubServer{err: status.Error(codes.InvalidArgument, "vignette not in season")}
	client := newClientForStub(t, stub)

	_, err := client.Score(context.Background(), playthrough.TraitScoringInput{
		PlaythroughID: "pt-1", SeasonID: "season-001", SeasonVersion: 1,
		Events: []playthrough.ScoredChoice{{VignetteID: "v-bogus", ChoiceID: "c-1"}},
	})
	if !errors.Is(err, ErrInvalidEvent) {
		t.Errorf("want ErrInvalidEvent, got %v", err)
	}
}
