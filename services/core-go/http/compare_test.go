package http

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
)

func createCompletedPlaythrough(t *testing.T, mux http.Handler, cookie string, choiceID string) uuid.UUID {
	t.Helper()

	createRec := doJSON(t, mux, http.MethodPost, "/playthroughs", cookie, map[string]string{"season_id": "season-001"})
	require.Equal(t, http.StatusCreated, createRec.Code, createRec.Body.String())

	var created playthroughResponse
	require.NoError(t, json.Unmarshal(createRec.Body.Bytes(), &created))

	recordRec := doJSON(t, mux, http.MethodPost, fmt.Sprintf("/playthroughs/%s/choices", created.Playthrough.ID.String()), cookie, map[string]any{
		"vignette_id": "vignette-001",
		"choice_id":   choiceID,
	})
	require.Equal(t, http.StatusOK, recordRec.Code, recordRec.Body.String())

	finalizeRec := doJSON(t, mux, http.MethodPost, fmt.Sprintf("/playthroughs/%s/finalize", created.Playthrough.ID.String()), cookie, nil)
	require.Equal(t, http.StatusOK, finalizeRec.Code, finalizeRec.Body.String())

	return created.Playthrough.ID
}

func hashTokenForTest(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func TestCompareFlow_ShareEnable_TokenGating_AndRevokeInvalidation(t *testing.T) {
	users := &fakeUsersRepo{user: auth.User{ID: uuid.New(), AgeBand: auth.AgeBandAdult}}
	mux, cookie, _ := newPlaythroughSuite(t, users)

	inviterID := users.user.ID
	inviterPlaythroughID := createCompletedPlaythrough(t, mux, cookie, "choice-1")

	users.user = auth.User{ID: uuid.New(), AgeBand: auth.AgeBandAdult}
	inviteeID := users.user.ID
	inviteePlaythroughID := createCompletedPlaythrough(t, mux, cookie, "choice-2")

	users.user = auth.User{ID: inviterID, AgeBand: auth.AgeBandAdult}
	createInviteRec := doJSON(t, mux, http.MethodPost, fmt.Sprintf("/playthroughs/%s/compare", inviterPlaythroughID.String()), cookie, nil)
	require.Equal(t, http.StatusCreated, createInviteRec.Code, createInviteRec.Body.String())

	var inviteResp compareInviteResponse
	require.NoError(t, json.Unmarshal(createInviteRec.Body.Bytes(), &inviteResp))
	require.NotEmpty(t, inviteResp.Token)

	users.user = auth.User{ID: inviteeID, AgeBand: auth.AgeBandAdult}
	acceptRec := doJSON(t, mux, http.MethodPost, "/compare/accept", cookie, map[string]any{
		"token":          inviteResp.Token,
		"playthrough_id": inviteePlaythroughID.String(),
	})
	require.Equal(t, http.StatusOK, acceptRec.Code, acceptRec.Body.String())

	inviteTokenPublicRead := doJSON(t, mux, http.MethodGet, "/compare/"+inviteResp.Token, "", nil)
	require.Equal(t, http.StatusNotFound, inviteTokenPublicRead.Code)

	users.user = auth.User{ID: inviterID, AgeBand: auth.AgeBandAdult}
	shareEnableRec := doJSON(t, mux, http.MethodPost, "/compare/"+inviteResp.Token+"/share-enable", cookie, nil)
	require.Equal(t, http.StatusOK, shareEnableRec.Code, shareEnableRec.Body.String())

	var shareResp shareEnableResponse
	require.NoError(t, json.Unmarshal(shareEnableRec.Body.Bytes(), &shareResp))
	require.NotEmpty(t, shareResp.ShareToken)

	shareRead := doJSON(t, mux, http.MethodGet, "/compare/"+shareResp.ShareToken, "", nil)
	require.Equal(t, http.StatusOK, shareRead.Code, shareRead.Body.String())
	var shareBody map[string]any
	require.NoError(t, json.Unmarshal(shareRead.Body.Bytes(), &shareBody))
	require.Len(t, shareBody, 5, "public compare payload shape should stay minimal")
	_, hasSeasonID := shareBody["season_id"]
	_, hasStatus := shareBody["status"]
	_, hasDivergence := shareBody["divergence"]
	_, hasInviterPNG := shareBody["inviter_png_url"]
	_, hasInviteePNG := shareBody["invitee_png_url"]
	require.True(t, hasSeasonID)
	require.True(t, hasStatus)
	require.True(t, hasDivergence)
	require.True(t, hasInviterPNG)
	require.True(t, hasInviteePNG)
	divergence, ok := shareBody["divergence"].(map[string]any)
	require.True(t, ok)
	require.Len(t, divergence, 3, "divergence payload must only expose one vignette + two choices")
	_, hasVignetteID := divergence["vignette_id"]
	_, hasInviterChoice := divergence["inviter_choice"]
	_, hasInviteeChoice := divergence["invitee_choice"]
	require.True(t, hasVignetteID)
	require.True(t, hasInviterChoice)
	require.True(t, hasInviteeChoice)
	_, hasComparison := shareBody["comparison"]
	_, hasInviterTraits := shareBody["inviter_traits"]
	_, hasInviteeTraits := shareBody["invitee_traits"]
	require.False(t, hasComparison, "public payload must not include internal comparison object")
	require.False(t, hasInviterTraits, "public payload must not include inviter trait vectors")
	require.False(t, hasInviteeTraits, "public payload must not include invitee trait vectors")

	revokeRec := doJSON(t, mux, http.MethodDelete, "/compare/"+inviteResp.Token, cookie, nil)
	require.Equal(t, http.StatusNoContent, revokeRec.Code, revokeRec.Body.String())

	readAfterRevoke := doJSON(t, mux, http.MethodGet, "/compare/"+shareResp.ShareToken, "", nil)
	require.Equal(t, http.StatusNotFound, readAfterRevoke.Code)
}

func TestComparePublicRead_ExpiredShareToken_ReturnsGone(t *testing.T) {
	users := &fakeUsersRepo{user: auth.User{ID: uuid.New(), AgeBand: auth.AgeBandAdult}}
	mux, cookie, repo := newPlaythroughSuite(t, users)

	inviterID := users.user.ID
	inviterPlaythroughID := createCompletedPlaythrough(t, mux, cookie, "choice-1")

	users.user = auth.User{ID: uuid.New(), AgeBand: auth.AgeBandAdult}
	inviteeID := users.user.ID
	inviteePlaythroughID := createCompletedPlaythrough(t, mux, cookie, "choice-2")

	users.user = auth.User{ID: inviterID, AgeBand: auth.AgeBandAdult}
	createInviteRec := doJSON(t, mux, http.MethodPost, fmt.Sprintf("/playthroughs/%s/compare", inviterPlaythroughID.String()), cookie, nil)
	require.Equal(t, http.StatusCreated, createInviteRec.Code, createInviteRec.Body.String())

	var inviteResp compareInviteResponse
	require.NoError(t, json.Unmarshal(createInviteRec.Body.Bytes(), &inviteResp))

	users.user = auth.User{ID: inviteeID, AgeBand: auth.AgeBandAdult}
	acceptRec := doJSON(t, mux, http.MethodPost, "/compare/accept", cookie, map[string]any{
		"token":          inviteResp.Token,
		"playthrough_id": inviteePlaythroughID.String(),
	})
	require.Equal(t, http.StatusOK, acceptRec.Code, acceptRec.Body.String())

	users.user = auth.User{ID: inviterID, AgeBand: auth.AgeBandAdult}
	shareEnableRec := doJSON(t, mux, http.MethodPost, "/compare/"+inviteResp.Token+"/share-enable", cookie, nil)
	require.Equal(t, http.StatusOK, shareEnableRec.Code, shareEnableRec.Body.String())

	var shareResp shareEnableResponse
	require.NoError(t, json.Unmarshal(shareEnableRec.Body.Bytes(), &shareResp))

	shareHash := hashTokenForTest(shareResp.ShareToken)
	shareKey := repo.tokenKey(shareHash, playthrough.ComparisonTokenTypeShare)
	tk := repo.compTokens[shareKey]
	expiredAt := time.Now().UTC().Add(-time.Minute)
	tk.ExpiresAt = expiredAt
	repo.compTokens[shareKey] = tk

	expiredRead := doJSON(t, mux, http.MethodGet, "/compare/"+shareResp.ShareToken, "", nil)
	require.Equal(t, http.StatusGone, expiredRead.Code, expiredRead.Body.String())
}

func TestCompareShareEnable_RequiresAcceptedComparison(t *testing.T) {
	users := &fakeUsersRepo{user: auth.User{ID: uuid.New(), AgeBand: auth.AgeBandAdult}}
	mux, cookie, _ := newPlaythroughSuite(t, users)

	playthroughID := createCompletedPlaythrough(t, mux, cookie, "choice-1")
	createInviteRec := doJSON(t, mux, http.MethodPost, fmt.Sprintf("/playthroughs/%s/compare", playthroughID.String()), cookie, nil)
	require.Equal(t, http.StatusCreated, createInviteRec.Code, createInviteRec.Body.String())

	var inviteResp compareInviteResponse
	require.NoError(t, json.Unmarshal(createInviteRec.Body.Bytes(), &inviteResp))

	shareEnableRec := doJSON(t, mux, http.MethodPost, "/compare/"+inviteResp.Token+"/share-enable", cookie, nil)
	require.Equal(t, http.StatusConflict, shareEnableRec.Code, shareEnableRec.Body.String())
}

func TestCompareRevoke_InviteeCanRevoke(t *testing.T) {
	users := &fakeUsersRepo{user: auth.User{ID: uuid.New(), AgeBand: auth.AgeBandAdult}}
	mux, cookie, _ := newPlaythroughSuite(t, users)

	inviterID := users.user.ID
	inviterPlaythroughID := createCompletedPlaythrough(t, mux, cookie, "choice-1")

	users.user = auth.User{ID: uuid.New(), AgeBand: auth.AgeBandAdult}
	inviteeID := users.user.ID
	inviteePlaythroughID := createCompletedPlaythrough(t, mux, cookie, "choice-2")

	users.user = auth.User{ID: inviterID, AgeBand: auth.AgeBandAdult}
	createInviteRec := doJSON(t, mux, http.MethodPost, fmt.Sprintf("/playthroughs/%s/compare", inviterPlaythroughID.String()), cookie, nil)
	require.Equal(t, http.StatusCreated, createInviteRec.Code, createInviteRec.Body.String())

	var inviteResp compareInviteResponse
	require.NoError(t, json.Unmarshal(createInviteRec.Body.Bytes(), &inviteResp))

	users.user = auth.User{ID: inviteeID, AgeBand: auth.AgeBandAdult}
	acceptRec := doJSON(t, mux, http.MethodPost, "/compare/accept", cookie, map[string]any{
		"token":          inviteResp.Token,
		"playthrough_id": inviteePlaythroughID.String(),
	})
	require.Equal(t, http.StatusOK, acceptRec.Code, acceptRec.Body.String())

	shareEnableRec := doJSON(t, mux, http.MethodPost, "/compare/"+inviteResp.Token+"/share-enable", cookie, nil)
	require.Equal(t, http.StatusOK, shareEnableRec.Code, shareEnableRec.Body.String())

	var shareResp shareEnableResponse
	require.NoError(t, json.Unmarshal(shareEnableRec.Body.Bytes(), &shareResp))

	revokeRec := doJSON(t, mux, http.MethodDelete, "/compare/"+inviteResp.Token, cookie, nil)
	require.Equal(t, http.StatusNoContent, revokeRec.Code, revokeRec.Body.String())

	readAfterRevoke := doJSON(t, mux, http.MethodGet, "/compare/"+shareResp.ShareToken, "", nil)
	require.Equal(t, http.StatusNotFound, readAfterRevoke.Code)
}

func TestCompareCreateInvite_YouthWithoutGuardianConsent_Forbidden(t *testing.T) {
	users := &fakeUsersRepo{user: auth.User{ID: uuid.New(), AgeBand: auth.AgeBandYouth}}
	mux, cookie, _ := newPlaythroughSuite(t, users)

	playthroughID := createCompletedPlaythrough(t, mux, cookie, "choice-1")
	createInviteRec := doJSON(t, mux, http.MethodPost, fmt.Sprintf("/playthroughs/%s/compare", playthroughID.String()), cookie, nil)
	require.Equal(t, http.StatusForbidden, createInviteRec.Code, createInviteRec.Body.String())
}

func TestCompareCreateInvite_YouthWithGuardianConsent_Allows(t *testing.T) {
	now := time.Now().UTC()
	users := &fakeUsersRepo{user: auth.User{
		ID:                                  uuid.New(),
		AgeBand:                             auth.AgeBandYouth,
		GuardianComparisonConsentVerifiedAt: &now,
	}}
	mux, cookie, _ := newPlaythroughSuite(t, users)

	playthroughID := createCompletedPlaythrough(t, mux, cookie, "choice-1")
	createInviteRec := doJSON(t, mux, http.MethodPost, fmt.Sprintf("/playthroughs/%s/compare", playthroughID.String()), cookie, nil)
	require.Equal(t, http.StatusCreated, createInviteRec.Code, createInviteRec.Body.String())
}




