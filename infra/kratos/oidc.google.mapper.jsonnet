// Maps Google OIDC claims into Echo identity traits.
// Birthdate and consent are supplied by the client in the registration
// POST body before the browser redirect (see AuthClient.signUpWithGoogle).
local claims = std.extVar('claims');
{
  identity: {
    traits: {
      email: claims.email,
      display_name:
        if std.objectHas(claims, 'name') && claims.name != ''
        then claims.name
        else claims.email,
    },
  },
}
