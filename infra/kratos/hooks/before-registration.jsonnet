// Before-registration web hook payload.
//
// Fires before Kratos creates the identity; the submitted form data is
// available on `ctx.flow.request_method_body`. We forward the birthdate
// trait to the Go backend, which runs the age gate (services/core-go/auth/)
// and rejects under-13 applicants by returning HTTP 422 with a `messages`
// body. Kratos config wires this with response.parse: true so the 422
// surfaces as a flow error without ever creating the identity.

function(ctx) {
  traits: {
    birthdate:
      if std.objectHas(ctx, 'flow')
         && std.objectHas(ctx.flow, 'request_method_body')
         && std.objectHas(ctx.flow.request_method_body, 'traits')
         && std.objectHas(ctx.flow.request_method_body.traits, 'birthdate')
      then ctx.flow.request_method_body.traits.birthdate
      else '',
  },
}
