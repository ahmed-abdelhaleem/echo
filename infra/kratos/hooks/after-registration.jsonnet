// After-registration web hook payload.
//
// Fires after Kratos creates the identity; `ctx.identity` is fully
// populated. We forward the identity id + birthdate to the Go backend,
// which provisions the `auth.users` row with the right age band. If the
// before-hook ever misses an under-13 applicant the backend's after-hook
// re-runs the gate and deletes the identity via the admin API.

function(ctx) {
  identity: {
    id: ctx.identity.id,
    traits: {
      birthdate:
        if std.objectHas(ctx.identity.traits, 'birthdate')
        then ctx.identity.traits.birthdate
        else '',
    },
  },
}
