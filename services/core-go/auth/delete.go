package auth

import (
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"
)

// DeleteMeConfig groups the dependencies the DELETE /me handler needs.
type DeleteMeConfig struct {
	Users  UsersRepository
	Kratos *KratosClient
	Logger *slog.Logger
	Now    func() time.Time
}

// DeleteMeHandler returns an HTTP handler that deletes the
// currently-authenticated user. The middleware must have attached a
// [Session] to the request context before this handler runs.
//
// Side effects, in order:
//  1. Soft-delete the row in `auth.users` (sets `deleted_at`). Done first
//     so that, if the Kratos delete succeeds and the session vanishes,
//     subsequent middleware lookups don't temporarily see an orphaned
//     row.
//  2. Delete the Kratos identity via the admin API. This terminates all
//     sessions including the one used by the request.
//
// Idempotent: a second call from a now-deleted session returns 401 at
// the middleware boundary, never reaching this handler.
func DeleteMeHandler(cfg DeleteMeConfig) http.HandlerFunc {
	if cfg.Users == nil {
		panic("auth: DeleteMeHandler requires UsersRepository")
	}
	if cfg.Kratos == nil {
		panic("auth: DeleteMeHandler requires KratosClient")
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
		sess, ok := SessionFromContext(r.Context())
		if !ok {
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "session not attached; middleware misconfigured",
			})
			return
		}

		identityID, err := uuid.Parse(sess.IdentityID)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "invalid identity id",
			})
			return
		}

		ctx := r.Context()
		if err := cfg.Users.SoftDeleteByKratosID(ctx, identityID, now()); err != nil {
			logger.ErrorContext(ctx, "delete /me: soft delete failed",
				"identity_id", identityID.String(),
				"err", err.Error(),
			)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "delete failed",
			})
			return
		}

		if err := cfg.Kratos.DeleteIdentity(ctx, identityID.String()); err != nil && !errors.Is(err, ErrIdentityNotFound) {
			logger.ErrorContext(ctx, "delete /me: kratos identity delete failed",
				"identity_id", identityID.String(),
				"err", err.Error(),
			)
			// The auth.users row is already gone. The dangling Kratos
			// identity will be cleaned up by the operator on next
			// reconciliation; do not crash the request.
			writeJSON(w, http.StatusAccepted, map[string]string{
				"status": "partial",
				"reason": "user row deleted; kratos identity delete pending",
			})
			return
		}

		logger.InfoContext(ctx, "delete /me: user deleted",
			"identity_id", identityID.String(),
		)
		w.WriteHeader(http.StatusNoContent)
	}
}
