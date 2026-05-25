// Package grpc wires the core-go service to the ml-py gRPC surface:
// TraitScoringService (T-ML-010), PortraitGenService (T-ML-020 stub),
// ReflectionGenService (T-ML-021 stub).
//
// Wire format lives under ./echopb (`make proto` regenerates from
// packages/proto/*.proto). This package exposes thin clients that
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

// MLClient holds the gRPC connection to ml-py. The single connection
// is shared across all three service clients (scorer / portrait /
// reflection) to keep socket churn down.
type MLClient struct {
	conn       *grpc.ClientConn
	scorer     echopb.TraitScoringServiceClient
	portrait   echopb.PortraitGenServiceClient
	reflection echopb.ReflectionGenServiceClient
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
		conn:       conn,
		scorer:     echopb.NewTraitScoringServiceClient(conn),
		portrait:   echopb.NewPortraitGenServiceClient(conn),
		reflection: echopb.NewReflectionGenServiceClient(conn),
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

// --- PortraitGenService (T-ML-020) -----------------------------------------

// ErrInvalidVector is returned when ml-py rejects the trait vector as
// the wrong shape (INVALID_ARGUMENT). Practically: a content authoring
// bug got past the validator, or a client called with a partial vector.
var ErrInvalidVector = errors.New("ml: invalid trait vector")

// PortraitGenClient adapts ml-py's PortraitGenService.
type PortraitGenClient interface {
	GeneratePortrait(ctx context.Context, in playthrough.PortraitInput) (playthrough.PortraitAssets, error)
}

// GeneratePortrait sends the trait vector to ml-py and returns the
// rendered Portrait. PNG bytes are always populated; AnimatedWebP is
// populated only when in.Animate was true (T-ML-031). StaticPNGKey /
// AnimatedWebPKey are populated by ml-py once T-CORE-030 wires R2
// persistence; empty otherwise.
func (c *MLClient) GeneratePortrait(ctx context.Context, in playthrough.PortraitInput) (playthrough.PortraitAssets, error) {
	req := &echopb.GeneratePortraitRequest{
		PlaythroughId: in.PlaythroughID,
		Seed:          in.Seed,
		BigFive:       in.BigFive,
		Schwartz:      in.Schwartz,
		Attachment:    in.Attachment,
		Animate:       in.Animate,
	}
	resp, err := c.portrait.Generate(ctx, req)
	if err != nil {
		return playthrough.PortraitAssets{}, translateVectorError(err, "portrait")
	}
	return playthrough.PortraitAssets{
		PNG:             resp.Png,
		AnimatedWebP:    resp.AnimatedWebp,
		StaticPNGKey:    resp.StaticPngKey,
		AnimatedWebPKey: resp.AnimatedWebpKey,
		RendererVersion: int(resp.RendererVersion),
	}, nil
}

// --- ReflectionGenService (T-ML-021) ---------------------------------------

// ReflectionGenClient adapts ml-py's ReflectionGenService.
type ReflectionGenClient interface {
	GenerateReflection(ctx context.Context, in playthrough.ReflectionInput) (playthrough.Reflection, error)
}

// GenerateReflection sends the trait vector + flags to ml-py and
// returns the templated reflection.
func (c *MLClient) GenerateReflection(ctx context.Context, in playthrough.ReflectionInput) (playthrough.Reflection, error) {
	req := &echopb.GenerateReflectionRequest{
		PlaythroughId: in.PlaythroughID,
		YouthSafe:     in.YouthSafe,
		Locale:        in.Locale,
		BigFive:       in.BigFive,
		Schwartz:      in.Schwartz,
		Attachment:    in.Attachment,
	}
	resp, err := c.reflection.Generate(ctx, req)
	if err != nil {
		return playthrough.Reflection{}, translateVectorError(err, "reflection")
	}
	return playthrough.Reflection{
		Text:         resp.Text,
		UsedFallback: resp.UsedFallback,
		TemplateID:   resp.TemplateId,
	}, nil
}

func translateVectorError(err error, surface string) error {
	st, ok := status.FromError(err)
	if !ok {
		return fmt.Errorf("%s: %w", surface, err)
	}
	switch st.Code() {
	case codes.InvalidArgument:
		return fmt.Errorf("%w: %s", ErrInvalidVector, st.Message())
	default:
		return fmt.Errorf("%s: rpc %s: %s", surface, st.Code(), st.Message())
	}
}
