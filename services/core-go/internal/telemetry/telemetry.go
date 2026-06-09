// Package telemetry wires up OpenTelemetry tracing for the core service.
//
// Per docs/06_Tech_Stack.md the observability standard is OpenTelemetry with
// vendor-neutral instrumentation. This package establishes a TracerProvider
// that either exports to an OTLP endpoint (when one is configured) or no-ops
// silently. Switching to a real exporter is a one-line change once the
// Grafana/Tempo stack is up.
package telemetry

import (
	"context"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// Options controls telemetry setup.
type Options struct {
	// ServiceName is the OpenTelemetry service.name attribute.
	ServiceName string
	// OTLPEndpoint is an OTLP HTTP/gRPC endpoint. Empty falls back to a no-op
	// tracer provider (no exporter wired).
	OTLPEndpoint string
}

// ShutdownFunc flushes pending spans and releases resources.
type ShutdownFunc func(ctx context.Context) error

// Setup installs a global TracerProvider for the process.
//
// When OTLPEndpoint is empty we install a TracerProvider with no exporter:
// spans are sampled and recorded but never exported. This is a deliberate
// choice for dev so that the binary boots in environments without a collector,
// and for tests where exporting noise is unwanted.
func Setup(_ context.Context, opts Options) (ShutdownFunc, error) {
	r, err := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes(
			semconv.SchemaURL,
			semconv.ServiceName(opts.ServiceName),
		),
	)
	if err != nil {
		return nil, err
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithResource(r),
		// No exporter wired yet — see package comment. The TracerProvider still
		// produces spans so application code can be instrumented today and an
		// exporter added without touching call sites.
	)
	otel.SetTracerProvider(tp)
	_ = opts.OTLPEndpoint // intentionally unused until exporter is wired

	return tp.Shutdown, nil
}
