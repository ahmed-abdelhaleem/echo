// Package grpc wires the core-go service to the ml-py gRPC surface
// (TraitScoringService for now; PortraitGen / Reflection land at M2).
//
// Wire format lives under ./echopb (`make proto` regenerates from
// packages/proto/*.proto). This package exposes a thin Client that
// callers (playthrough.Service in particular) can depend on without
// reaching into the generated code.
package grpc

import (
	"context"
	"errors"
	"fmt"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/grpc/echopb"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

// ErrSeasonNotFound is returned when the trait scoring service does not
// recognise the Season id (NOT_FOUND from ml-py).
var ErrSeasonNotFound = errors.New("trait scoring: season not found")

// ErrInvalidEvent is returned when a (vignette, choice) pair is rejected
// as not present in the Season (INVALID_ARGUMENT from ml-py).
var ErrInvalidEvent = errors.New("trait scoring: invalid choice event")

// TraitScoringClient is the core-go-side adapter for ml-py's
// TraitScoringService. The interface keeps the playthrough layer testable
// without standing up a real gRPC server.
type TraitScoringClient interface {
	Score(ctx context.Context, in playthrough.TraitScoringInput) (playthrough.TraitVector, error)
}

// MLClient holds the gRPC connection to ml-py.
type MLClient struct {
	conn   *grpc.ClientConn
	scorer echopb.TraitScoringServiceClient
}

// DialML opens an insecure gRPC connection to ml-py. Insecure is
// acceptable today because both services run inside the same VPC; M2
// adds mTLS once the cluster topology is decided.
func DialML(ctx context.Context, target string) (*MLClient, error) {
	conn, err := grpc.NewClient(target,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		return nil, fmt.Errorf("grpc: dial ml at %s: %w", target, err)
	}
	return &MLClient{
		conn:   conn,
		scorer: echopb.NewTraitScoringServiceClient(conn),
	}, nil
}

// Close releases the underlying connection.
func (c *MLClient) Close() error {
	if c == nil || c.conn == nil {
		return nil
	}
	return c.conn.Close()
}

// Score sends the (season, events) tuple to ml-py and translates the
// response into the playthrough domain types.
func (c *MLClient) Score(ctx context.Context, in playthrough.TraitScoringInput) (playthrough.TraitVector, error) {
	req := &echopb.ScoreRequest{
		PlaythroughId: in.PlaythroughID,
		SeasonId:      in.SeasonID,
		SeasonVersion: int32(in.SeasonVersion),
		Events:        make([]*echopb.ScoredChoice, 0, len(in.Events)),
	}
	for _, ev := range in.Events {
		req.Events = append(req.Events, &echopb.ScoredChoice{
			VignetteId: ev.VignetteID,
			ChoiceId:   ev.ChoiceID,
		})
	}
	resp, err := c.scorer.Score(ctx, req)
	if err != nil {
		return playthrough.TraitVector{}, translateScoreError(err)
	}
	return playthrough.TraitVector{
		BigFive:    resp.BigFive,
		Schwartz:   resp.Schwartz,
		Attachment: resp.Attachment,
	}, nil
}

// translateScoreError maps gRPC status codes to domain error sentinels so
// the playthrough layer doesn't have to import google.golang.org/grpc.
func translateScoreError(err error) error {
	st, ok := status.FromError(err)
	if !ok {
		return fmt.Errorf("trait scoring: %w", err)
	}
	switch st.Code() {
	case codes.NotFound:
		return fmt.Errorf("%w: %s", ErrSeasonNotFound, st.Message())
	case codes.InvalidArgument:
		return fmt.Errorf("%w: %s", ErrInvalidEvent, st.Message())
	default:
		return fmt.Errorf("trait scoring: rpc %s: %s", st.Code(), st.Message())
	}
}
