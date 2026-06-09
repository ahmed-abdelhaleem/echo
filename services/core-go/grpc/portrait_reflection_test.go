package grpc

import (
	"bytes"
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

// portraitStub records the request and returns a fixed PNG.
type portraitStub struct {
	echopb.UnimplementedPortraitGenServiceServer
	gotReq *echopb.GeneratePortraitRequest
	resp   *echopb.GeneratePortraitResponse
	err    error
}

func (s *portraitStub) Generate(_ context.Context, in *echopb.GeneratePortraitRequest) (*echopb.GeneratePortraitResponse, error) {
	s.gotReq = in
	if s.err != nil {
		return nil, s.err
	}
	return s.resp, nil
}

// reflectionStub records the request and returns a fixed reflection.
type reflectionStub struct {
	echopb.UnimplementedReflectionGenServiceServer
	gotReq *echopb.GenerateReflectionRequest
	resp   *echopb.GenerateReflectionResponse
	err    error
}

func (s *reflectionStub) Generate(_ context.Context, in *echopb.GenerateReflectionRequest) (*echopb.GenerateReflectionResponse, error) {
	s.gotReq = in
	if s.err != nil {
		return nil, s.err
	}
	return s.resp, nil
}

// newPortraitReflectionClient stands up a real gRPC server on a random
// port serving the supplied stubs and returns an MLClient connected to
// it. Modeled after newClientForStub in grpc_test.go.
func newPortraitReflectionClient(t *testing.T, portrait *portraitStub, reflection *reflectionStub) *MLClient {
	t.Helper()

	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen: %v", err)
	}
	srv := grpc.NewServer()
	if portrait != nil {
		echopb.RegisterPortraitGenServiceServer(srv, portrait)
	}
	if reflection != nil {
		echopb.RegisterReflectionGenServiceServer(srv, reflection)
	}
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(func() { srv.Stop() })

	time.Sleep(20 * time.Millisecond)

	conn, err := grpc.NewClient(lis.Addr().String(),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("grpc.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	return &MLClient{
		conn:       conn,
		portrait:   echopb.NewPortraitGenServiceClient(conn),
		reflection: echopb.NewReflectionGenServiceClient(conn),
	}
}

// --- Portrait ---------------------------------------------------------------

func TestMLClient_GeneratePortrait_HappyPath_TranslatesPayload(t *testing.T) {
	stub := &portraitStub{
		resp: &echopb.GeneratePortraitResponse{
			Png:             []byte("\x89PNGFAKE"),
			RendererVersion: 2,
		},
	}
	client := newPortraitReflectionClient(t, stub, nil)

	got, err := client.GeneratePortrait(context.Background(), playthrough.PortraitInput{
		PlaythroughID: "pt-1",
		Seed:          42,
		BigFive:       []float64{0.1, 0, 0, 0, 0},
		Schwartz:      make([]float64, 10),
		Attachment:    []float64{0.2, 0, 0},
	})
	if err != nil {
		t.Fatalf("GeneratePortrait: %v", err)
	}
	if !bytes.Equal(got.PNG, []byte("\x89PNGFAKE")) {
		t.Errorf("png round-trip broke: %q", got.PNG)
	}
	if got.RendererVersion != 2 {
		t.Errorf("renderer version: want 2, got %d", got.RendererVersion)
	}
	if stub.gotReq.PlaythroughId != "pt-1" {
		t.Errorf("playthrough_id: want pt-1, got %q", stub.gotReq.PlaythroughId)
	}
	if stub.gotReq.Seed != 42 {
		t.Errorf("seed: want 42, got %d", stub.gotReq.Seed)
	}
	if stub.gotReq.Animate {
		t.Error("animate must default to false on the wire")
	}
	if len(stub.gotReq.BigFive) != 5 || len(stub.gotReq.Schwartz) != 10 || len(stub.gotReq.Attachment) != 3 {
		t.Errorf("vector shape lost on the wire: %d/%d/%d",
			len(stub.gotReq.BigFive), len(stub.gotReq.Schwartz), len(stub.gotReq.Attachment))
	}
}

func TestMLClient_GeneratePortrait_AnimateRoundTripsWebPBytes(t *testing.T) {
	stub := &portraitStub{
		resp: &echopb.GeneratePortraitResponse{
			Png:             []byte("\x89PNGFAKE"),
			AnimatedWebp:    []byte("RIFFFAKEWEBPVP8L"),
			RendererVersion: 2,
		},
	}
	client := newPortraitReflectionClient(t, stub, nil)

	got, err := client.GeneratePortrait(context.Background(), playthrough.PortraitInput{
		PlaythroughID: "pt-1",
		BigFive:       []float64{0, 0, 0, 0, 0},
		Schwartz:      make([]float64, 10),
		Attachment:    []float64{0, 0, 0},
		Animate:       true,
	})
	if err != nil {
		t.Fatalf("GeneratePortrait: %v", err)
	}
	if !stub.gotReq.Animate {
		t.Error("animate must be propagated to the wire request")
	}
	if !bytes.Equal(got.AnimatedWebP, []byte("RIFFFAKEWEBPVP8L")) {
		t.Errorf("animated webp round-trip broke: %q", got.AnimatedWebP)
	}
}

func TestMLClient_GeneratePortrait_InvalidArgumentMapsToErrInvalidVector(t *testing.T) {
	stub := &portraitStub{err: status.Error(codes.InvalidArgument, "big_five must have 5 values")}
	client := newPortraitReflectionClient(t, stub, nil)

	_, err := client.GeneratePortrait(context.Background(), playthrough.PortraitInput{
		PlaythroughID: "pt-1",
		BigFive:       []float64{0, 0, 0, 0}, // too short
		Schwartz:      make([]float64, 10),
		Attachment:    []float64{0, 0, 0},
	})
	if !errors.Is(err, ErrInvalidVector) {
		t.Errorf("want ErrInvalidVector, got %v", err)
	}
}

// --- Reflection -------------------------------------------------------------

func TestMLClient_GenerateReflection_HappyPath_TranslatesPayload(t *testing.T) {
	stub := &reflectionStub{
		resp: &echopb.GenerateReflectionResponse{
			Text:         "Today, you reach toward what is unfamiliar.",
			UsedFallback: false,
			TemplateId:   "m1-stub.v1",
		},
	}
	client := newPortraitReflectionClient(t, nil, stub)

	got, err := client.GenerateReflection(context.Background(), playthrough.ReflectionInput{
		PlaythroughID: "pt-1",
		YouthSafe:     true,
		Locale:        "en-GB",
		BigFive:       []float64{0.9, 0, 0, 0, 0},
		Schwartz:      make([]float64, 10),
		Attachment:    []float64{0, 0, 0},
	})
	if err != nil {
		t.Fatalf("GenerateReflection: %v", err)
	}
	if got.Text != "Today, you reach toward what is unfamiliar." {
		t.Errorf("text passthrough broke: %q", got.Text)
	}
	if got.TemplateID != "m1-stub.v1" {
		t.Errorf("template_id: want m1-stub.v1, got %q", got.TemplateID)
	}
	if got.UsedFallback {
		t.Errorf("used_fallback should be false for the stub, got true")
	}
	if !stub.gotReq.YouthSafe {
		t.Errorf("youth_safe flag lost on the wire")
	}
	if stub.gotReq.Locale != "en-GB" {
		t.Errorf("locale: want en-GB, got %q", stub.gotReq.Locale)
	}
}

func TestMLClient_GenerateReflection_InvalidArgumentMapsToErrInvalidVector(t *testing.T) {
	stub := &reflectionStub{err: status.Error(codes.InvalidArgument, "schwartz must have 10 values")}
	client := newPortraitReflectionClient(t, nil, stub)

	_, err := client.GenerateReflection(context.Background(), playthrough.ReflectionInput{
		PlaythroughID: "pt-1",
		BigFive:       []float64{0, 0, 0, 0, 0},
		Schwartz:      []float64{0, 0, 0, 0, 0, 0, 0, 0, 0}, // too short
		Attachment:    []float64{0, 0, 0},
	})
	if !errors.Is(err, ErrInvalidVector) {
		t.Errorf("want ErrInvalidVector, got %v", err)
	}
}
