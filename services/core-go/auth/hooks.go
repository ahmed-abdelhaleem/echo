package auth

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"
)

// HookSecretHeader is the HTTP header Kratos must include when invoking
// the registration web hooks. The value is compared against the
// `KRATOS_HOOK_SECRET` env var in constant time.
const HookSecretHeader = "X-Echo-Hook-Secret"

// HookConfig groups the dependencies the Kratos registration hooks need.
type HookConfig struct {
	// Secret is the shared secret Kratos sends in [HookSecretHeader].
	// Both Kratos and Echo are configured with the same value at deploy
	// time. The empty string disables the secret check, which is only
	// acceptable in tests.
	Secret string

	// Users is the persistence layer used to provision rows in
	// `auth.users` after a successful registration.
	Users UsersRepository

	// Kratos is the admin-API client used to roll back identities that
	// fail the age-gate. The after-registration hook fires *after*
	// Kratos has created the identity, so the only way to enforce
	// under-13 rejection at this point is to delete the identity
	// immediately.
	Kratos *KratosClient

	// Logger is used to record hook outcomes. Defaults to slog.Default.
	Logger *slog.Logger

	// Now is the time source for stamping consent rows. Defaults to time.Now.
	Now func() time.Time
}

// BeforeRegistrationPayload is the body Kratos POSTs to the
// before-registration web hook. Only the birthdate matters for the gate;
// the identity id does not exist yet at this stage.
type BeforeRegistrationPayload struct {
	Traits struct {
		Birthdate string `json:"birthdate"`
	} `json:"traits"`
}

// AfterRegistrationPayload is the body Kratos POSTs to the
// after-registration web hook. The identity has been created by this
// point so we have its id.
type AfterRegistrationPayload struct {
	Identity struct {
		ID     string `json:"id"`
		Traits struct {
			Birthdate string `json:"birthdate"`
		} `json:"traits"`
	} `json:"identity"`
}

// BeforeRegistrationHandler validates the registration payload's
// birthdate against the age gate. Returns 200 OK if the applicant is
// allowed; 422 Unprocessable Entity (with a JSON error body Kratos can
// surface to the client) if under-13.
//
// Wiring: kratos.yml configures this endpoint as a
// `selfservice.flows.registration.before` web_hook with
// `response.parse: true` so Kratos respects the non-2xx response.
func BeforeRegistrationHandler(cfg HookConfig) http.HandlerFunc {
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyHookSecret(w, r, cfg.Secret) {
			return
		}

		var payload BeforeRegistrationPayload
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			logger.WarnContext(r.Context(), "before-registration: bad payload", "err", err.Error())
			writeHookError(w, http.StatusBadRequest, "invalid payload")
			return
		}

		if payload.Traits.Birthdate == "" {
			// Flow initialization or empty input — do not reject with 400,
			// let it pass to allow the form flow to display to the user.
			writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
			return
		}

		decision, err := EvaluateAgeGate(payload.Traits.Birthdate, now())
		if err != nil {
			logger.WarnContext(r.Context(), "before-registration: invalid birthdate format", "err", err.Error())
			writeHookError(w, http.StatusBadRequest, "invalid birthdate")
			return
		}
		if !decision.Allowed {
			logger.InfoContext(r.Context(), "before-registration: applicant rejected by age gate")
			// 422 with a `messages` field so Kratos can surface the
			// reason to the client via parse_response. The shape
			// mirrors what Kratos uses internally for field errors.
			writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
				"messages": []map[string]any{
					{
						"instance_ptr": "#/traits/birthdate",
						"messages": []map[string]any{
							{
								"id":   1_000_001,
								"text": decision.Reason,
								"type": "error",
							},
						},
					},
				},
			})
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

// AfterRegistrationHandler provisions an `auth.users` row for the
// freshly-created Kratos identity. Defense in depth: even though
// [BeforeRegistrationHandler] rejects under-13 applicants, this handler
// re-runs the gate; if it ever fires with an under-13 birthdate it
// deletes the identity via the Kratos admin API rather than provisioning.
//
// Idempotency: the hook may be retried by Kratos. Both code paths
// (provision + delete) are idempotent.
func AfterRegistrationHandler(cfg HookConfig) http.HandlerFunc {
	if cfg.Users == nil {
		panic("auth: AfterRegistrationHandler requires UsersRepository")
	}
	if cfg.Kratos == nil {
		panic("auth: AfterRegistrationHandler requires KratosClient")
	}
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyHookSecret(w, r, cfg.Secret) {
			return
		}

		var payload AfterRegistrationPayload
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			logger.WarnContext(r.Context(), "after-registration: bad payload", "err", err.Error())
			writeHookError(w, http.StatusBadRequest, "invalid payload")
			return
		}

		identityID, err := uuid.Parse(payload.Identity.ID)
		if err != nil {
			writeHookError(w, http.StatusBadRequest, "invalid identity id")
			return
		}

		decision, err := EvaluateAgeGate(payload.Identity.Traits.Birthdate, now())
		if err != nil {
			// Birthdate unparseable at this point is a programming
			// error (the schema validates it). Roll back to be safe.
			rollbackIdentity(r, cfg, identityID, "invalid birthdate", logger)
			writeHookError(w, http.StatusBadRequest, "invalid birthdate")
			return
		}
		if !decision.Allowed {
			// Under-13 slipped through the before-hook somehow.
			// Tear the identity down.
			rollbackIdentity(r, cfg, identityID, "under-13", logger)
			writeHookError(w, http.StatusUnprocessableEntity, decision.Reason)
			return
		}

		if _, err := cfg.Users.EnsureForKratosIdentity(r.Context(), identityID, decision.Band, now()); err != nil {
			logger.ErrorContext(r.Context(), "after-registration: provision failed",
				"identity_id", identityID.String(),
				"err", err.Error(),
			)
			writeHookError(w, http.StatusInternalServerError, "provision failed")
			return
		}

		logger.InfoContext(r.Context(), "after-registration: provisioned user",
			"identity_id", identityID.String(),
			"band", string(decision.Band),
		)
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

// rollbackIdentity deletes a freshly-created Kratos identity. Best-effort:
// on failure it logs but does not retry — Kratos's audit log records the
// delete attempt and an operator can clean up manually if needed.
func rollbackIdentity(r *http.Request, cfg HookConfig, identityID uuid.UUID, reason string, logger *slog.Logger) {
	if err := cfg.Kratos.DeleteIdentity(r.Context(), identityID.String()); err != nil && !errors.Is(err, ErrIdentityNotFound) {
		logger.ErrorContext(r.Context(), "after-registration: identity rollback failed",
			"identity_id", identityID.String(),
			"reason", reason,
			"err", err.Error(),
		)
		return
	}
	logger.InfoContext(r.Context(), "after-registration: identity rolled back",
		"identity_id", identityID.String(),
		"reason", reason,
	)
}

// verifyHookSecret returns true iff the request carries the expected
// shared secret. Returns false (and writes 401) otherwise. Constant-time
// comparison so a misconfigured hook secret never reveals which prefix
// matched.
func verifyHookSecret(w http.ResponseWriter, r *http.Request, expected string) bool {
	if expected == "" {
		// Tests run without a secret; production wires one in.
		return true
	}
	got := r.Header.Get(HookSecretHeader)
	if subtle.ConstantTimeCompare([]byte(got), []byte(expected)) != 1 {
		writeHookError(w, http.StatusUnauthorized, "invalid hook secret")
		return false
	}
	return true
}

func writeHookError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
