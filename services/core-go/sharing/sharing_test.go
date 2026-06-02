package sharing_test

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/sharing"
	"github.com/google/uuid"
)

// ---- test doubles --------------------------------------------------------

// memRepo is an in-memory sharing.Repository keyed by token.
type memRepo struct {
	mu       sync.Mutex
	links    map[string]sharing.Link
	insertEr error
}

func newMemRepo() *memRepo {
	return &memRepo{links: make(map[string]sharing.Link)}
}

func (r *memRepo) Insert(_ context.Context, l sharing.Link) (sharing.Link, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.insertEr != nil {
		return sharing.Link{}, r.insertEr
	}
	if _, dup := r.links[l.Token]; dup {
		return sharing.Link{}, errors.New("duplicate token")
	}
	if l.CreatedAt.IsZero() {
		l.CreatedAt = time.Now()
	}
	r.links[l.Token] = l
	return l, nil
}

func (r *memRepo) GetByToken(_ context.Context, token string) (sharing.Link, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	l, ok := r.links[token]
	if !ok {
		return sharing.Link{}, sharing.ErrLinkNotFound
	}
	return l, nil
}

func (r *memRepo) Revoke(_ context.Context, token string, userID uuid.UUID, now time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	l, ok := r.links[token]
	if !ok {
		return sharing.ErrLinkNotFound
	}
	if l.UserID != userID {
		return sharing.ErrNotOwner
	}
	if l.RevokedAt != nil {
		return nil
	}
	t := now
	l.RevokedAt = &t
	r.links[token] = l
	return nil
}

func (r *memRepo) IncrementViewCount(_ context.Context, token string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	l, ok := r.links[token]
	if !ok {
		return sharing.ErrLinkNotFound
	}
	l.ViewCount++
	r.links[token] = l
	return nil
}

func (r *memRepo) ListByPlaythrough(_ context.Context, id uuid.UUID) ([]sharing.Link, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []sharing.Link
	for _, l := range r.links {
		if l.PlaythroughID == id {
			out = append(out, l)
		}
	}
	return out, nil
}

// fakePlaythroughs is a minimal PlaythroughReader.
type fakePlaythroughs struct {
	m map[uuid.UUID]playthrough.Playthrough
}

func (f fakePlaythroughs) GetPlaythrough(_ context.Context, id uuid.UUID) (playthrough.Playthrough, error) {
	p, ok := f.m[id]
	if !ok {
		return playthrough.Playthrough{}, playthrough.ErrNotFound
	}
	return p, nil
}

// fakeUsers is a minimal UsersRepository.
type fakeUsers struct {
	m map[uuid.UUID]auth.User
}

func (f fakeUsers) GetByKratosID(_ context.Context, _ uuid.UUID) (auth.User, error) {
	return auth.User{}, auth.ErrUserNotFound
}
func (f fakeUsers) GetByID(_ context.Context, id uuid.UUID) (auth.User, error) {
	u, ok := f.m[id]
	if !ok {
		return auth.User{}, auth.ErrUserNotFound
	}
	return u, nil
}
func (f fakeUsers) EnsureFromSession(_ context.Context, _ auth.Session, _ time.Time) (auth.User, error) {
	return auth.User{}, nil
}
func (f fakeUsers) EnsureForKratosIdentity(_ context.Context, _ uuid.UUID, _ auth.AgeBand, _ time.Time) (auth.User, error) {
	return auth.User{}, nil
}
func (f fakeUsers) SoftDeleteByKratosID(_ context.Context, _ uuid.UUID, _ time.Time) error {
	return nil
}

// fixedTokens hands out tokens from a slice, in order. Tests that need
// deterministic tokens supply this.
type fixedTokens struct {
	values []string
	i      int
}

func (s *fixedTokens) NewToken() (string, error) {
	if s.i >= len(s.values) {
		return "", errors.New("fixed token source exhausted")
	}
	v := s.values[s.i]
	s.i++
	return v, nil
}

// ---- helpers -------------------------------------------------------------

type fixtures struct {
	adultID uuid.UUID
	youthID uuid.UUID
	otherID uuid.UUID
	ptID    uuid.UUID
	users   fakeUsers
	pts     fakePlaythroughs
}

func newFixtures() fixtures {
	adultID := uuid.New()
	youthID := uuid.New()
	otherID := uuid.New()
	ptID := uuid.New()
	completedAt := time.Date(2026, 5, 21, 9, 0, 0, 0, time.UTC)
	return fixtures{
		adultID: adultID,
		youthID: youthID,
		otherID: otherID,
		ptID:    ptID,
		users: fakeUsers{m: map[uuid.UUID]auth.User{
			adultID: {ID: adultID, AgeBand: auth.AgeBandAdult},
			youthID: {ID: youthID, AgeBand: auth.AgeBandYouth},
			otherID: {ID: otherID, AgeBand: auth.AgeBandAdult},
		}},
		pts: fakePlaythroughs{m: map[uuid.UUID]playthrough.Playthrough{
			ptID: {ID: ptID, UserID: adultID, Status: playthrough.StatusCompleted, CompletedAt: &completedAt},
		}},
	}
}

func newService(t *testing.T, repo sharing.Repository, fx fixtures, tokens sharing.TokenSource) *sharing.Service {
	t.Helper()
	cfg := sharing.Config{
		Repository:   repo,
		Playthroughs: fx.pts,
		Users:        fx.users,
		Tokens:       tokens,
		Now:          func() time.Time { return time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC) },
	}
	return sharing.New(cfg)
}

// ---- Create --------------------------------------------------------------

func TestCreate_AdultHappyPath(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-aaa"}})

	link, err := svc.Create(context.Background(), sharing.CreateInput{
		UserID:        fx.adultID,
		PlaythroughID: fx.ptID,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if link.Token != "tok-aaa" {
		t.Errorf("token: got %q, want tok-aaa", link.Token)
	}
	if link.UserID != fx.adultID {
		t.Errorf("user: got %v, want %v", link.UserID, fx.adultID)
	}
	if link.IsRevoked() {
		t.Error("freshly-created link is revoked")
	}
}

func TestCreate_YouthSafeDenied(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	// Re-point the playthrough at the youth user so ownership passes.
	pt := fx.pts.m[fx.ptID]
	pt.UserID = fx.youthID
	fx.pts.m[fx.ptID] = pt

	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-aaa"}})

	_, err := svc.Create(context.Background(), sharing.CreateInput{
		UserID:        fx.youthID,
		PlaythroughID: fx.ptID,
	})
	if !errors.Is(err, sharing.ErrYouthSafeDenied) {
		t.Fatalf("err: got %v, want ErrYouthSafeDenied", err)
	}
	// Critical: no row was inserted (no side effects on failure).
	if len(repo.links) != 0 {
		t.Errorf("repo writes on youth-safe failure: %d", len(repo.links))
	}
}

func TestCreate_NotOwner(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-aaa"}})

	_, err := svc.Create(context.Background(), sharing.CreateInput{
		UserID:        fx.otherID, // different from playthrough owner
		PlaythroughID: fx.ptID,
	})
	if !errors.Is(err, sharing.ErrNotOwner) {
		t.Fatalf("err: got %v, want ErrNotOwner", err)
	}
	if len(repo.links) != 0 {
		t.Errorf("repo writes on not-owner failure: %d", len(repo.links))
	}
}

func TestCreate_PlaythroughMissingIsNotOwner(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-aaa"}})

	_, err := svc.Create(context.Background(), sharing.CreateInput{
		UserID:        fx.adultID,
		PlaythroughID: uuid.New(), // doesn't exist
	})
	// Mapping ErrNotFound -> ErrNotOwner is intentional; we do not
	// confirm playthrough existence to anyone other than the owner.
	if !errors.Is(err, sharing.ErrNotOwner) {
		t.Fatalf("err: got %v, want ErrNotOwner", err)
	}
}

func TestCreate_PlaythroughIncomplete(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	pt := fx.pts.m[fx.ptID]
	pt.Status = playthrough.StatusInProgress
	pt.CompletedAt = nil
	fx.pts.m[fx.ptID] = pt

	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-aaa"}})

	_, err := svc.Create(context.Background(), sharing.CreateInput{
		UserID:        fx.adultID,
		PlaythroughID: fx.ptID,
	})
	if !errors.Is(err, sharing.ErrPlaythroughNotComplete) {
		t.Fatalf("err: got %v, want ErrPlaythroughNotComplete", err)
	}
}

func TestCreate_EmptyUserIDRejected(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-aaa"}})

	_, err := svc.Create(context.Background(), sharing.CreateInput{
		UserID:        uuid.Nil,
		PlaythroughID: fx.ptID,
	})
	if err == nil {
		t.Fatal("expected error for nil user id")
	}
}

func TestCreate_TokenSourceFailurePropagates(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: nil}) // exhausted

	_, err := svc.Create(context.Background(), sharing.CreateInput{
		UserID:        fx.adultID,
		PlaythroughID: fx.ptID,
	})
	if err == nil {
		t.Fatal("expected token source failure")
	}
	if len(repo.links) != 0 {
		t.Errorf("repo wrote on token failure: %d", len(repo.links))
	}
}

// ---- GetByToken ----------------------------------------------------------

func TestGetByToken_HappyPath(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-live"}})

	_, err := svc.Create(context.Background(), sharing.CreateInput{
		UserID:        fx.adultID,
		PlaythroughID: fx.ptID,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	got, err := svc.GetByToken(context.Background(), "tok-live")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.PlaythroughID != fx.ptID {
		t.Errorf("playthrough: got %v, want %v", got.PlaythroughID, fx.ptID)
	}
	// View count should have been bumped exactly once.
	if got2, _ := repo.GetByToken(context.Background(), "tok-live"); got2.ViewCount != 1 {
		t.Errorf("view count: got %d, want 1", got2.ViewCount)
	}
}

func TestGetByToken_NotFound(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-x"}})

	_, err := svc.GetByToken(context.Background(), "nope")
	if !errors.Is(err, sharing.ErrLinkNotFound) {
		t.Fatalf("err: got %v, want ErrLinkNotFound", err)
	}
}

func TestGetByToken_EmptyTokenIsNotFound(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-x"}})

	_, err := svc.GetByToken(context.Background(), "")
	if !errors.Is(err, sharing.ErrLinkNotFound) {
		t.Fatalf("err: got %v, want ErrLinkNotFound", err)
	}
}

func TestGetByToken_Revoked(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-dead"}})

	_, err := svc.Create(context.Background(), sharing.CreateInput{
		UserID:        fx.adultID,
		PlaythroughID: fx.ptID,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if err := svc.Revoke(context.Background(), "tok-dead", fx.adultID); err != nil {
		t.Fatalf("revoke: %v", err)
	}

	_, err = svc.GetByToken(context.Background(), "tok-dead")
	if !errors.Is(err, sharing.ErrLinkRevoked) {
		t.Fatalf("err: got %v, want ErrLinkRevoked", err)
	}
}

// ---- Revoke --------------------------------------------------------------

func TestRevoke_HappyPath(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-r1"}})

	_, _ = svc.Create(context.Background(), sharing.CreateInput{
		UserID:        fx.adultID,
		PlaythroughID: fx.ptID,
	})

	if err := svc.Revoke(context.Background(), "tok-r1", fx.adultID); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	got, _ := repo.GetByToken(context.Background(), "tok-r1")
	if !got.IsRevoked() {
		t.Error("expected link to be revoked")
	}
}

func TestRevoke_Idempotent(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-r2"}})

	_, _ = svc.Create(context.Background(), sharing.CreateInput{
		UserID:        fx.adultID,
		PlaythroughID: fx.ptID,
	})

	if err := svc.Revoke(context.Background(), "tok-r2", fx.adultID); err != nil {
		t.Fatalf("first revoke: %v", err)
	}
	// Second revoke must be a no-op.
	if err := svc.Revoke(context.Background(), "tok-r2", fx.adultID); err != nil {
		t.Fatalf("second revoke (idempotency): %v", err)
	}
}

func TestRevoke_NotOwner(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"tok-r3"}})

	_, _ = svc.Create(context.Background(), sharing.CreateInput{
		UserID:        fx.adultID,
		PlaythroughID: fx.ptID,
	})

	err := svc.Revoke(context.Background(), "tok-r3", fx.otherID)
	if !errors.Is(err, sharing.ErrNotOwner) {
		t.Fatalf("err: got %v, want ErrNotOwner", err)
	}
}

func TestRevoke_TokenMissingIsNotFound(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"unused"}})

	err := svc.Revoke(context.Background(), "nope", fx.adultID)
	if !errors.Is(err, sharing.ErrLinkNotFound) {
		t.Fatalf("err: got %v, want ErrLinkNotFound", err)
	}
}

func TestRevoke_EmptyTokenIsNotFound(t *testing.T) {
	t.Parallel()
	fx := newFixtures()
	repo := newMemRepo()
	svc := newService(t, repo, fx, &fixedTokens{values: []string{"unused"}})

	err := svc.Revoke(context.Background(), "", fx.adultID)
	if !errors.Is(err, sharing.ErrLinkNotFound) {
		t.Fatalf("err: got %v, want ErrLinkNotFound", err)
	}
}

// ---- Token entropy + format ---------------------------------------------

func TestNewTokenSource_FormatAndEntropy(t *testing.T) {
	t.Parallel()
	src := sharing.NewTokenSource()
	seen := make(map[string]struct{}, 1024)
	for i := 0; i < 1024; i++ {
		tok, err := src.NewToken()
		if err != nil {
			t.Fatalf("token: %v", err)
		}
		// 22 chars, no padding, base64url alphabet.
		if len(tok) != 22 {
			t.Fatalf("token length %d, want 22 (16 bytes base64url no padding)", len(tok))
		}
		if strings.ContainsAny(tok, "+/=") {
			t.Fatalf("token %q contains non-urlsafe chars", tok)
		}
		if _, dup := seen[tok]; dup {
			t.Fatalf("token collision after %d draws: %q", i, tok)
		}
		seen[tok] = struct{}{}
	}
}

// ---- Constructor invariants ---------------------------------------------

func TestNew_PanicsOnNilRepo(t *testing.T) {
	t.Parallel()
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("expected panic on nil repo")
		}
	}()
	_ = sharing.New(sharing.Config{
		Repository:   nil,
		Playthroughs: fakePlaythroughs{m: map[uuid.UUID]playthrough.Playthrough{}},
		Users:        fakeUsers{m: map[uuid.UUID]auth.User{}},
	})
}

func TestNew_PanicsOnNilPlaythroughs(t *testing.T) {
	t.Parallel()
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("expected panic on nil playthroughs")
		}
	}()
	_ = sharing.New(sharing.Config{
		Repository:   newMemRepo(),
		Playthroughs: nil,
		Users:        fakeUsers{m: map[uuid.UUID]auth.User{}},
	})
}

func TestNew_PanicsOnNilUsers(t *testing.T) {
	t.Parallel()
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("expected panic on nil users")
		}
	}()
	_ = sharing.New(sharing.Config{
		Repository:   newMemRepo(),
		Playthroughs: fakePlaythroughs{m: map[uuid.UUID]playthrough.Playthrough{}},
		Users:        nil,
	})
}

func TestNew_DefaultsTokenAndNow(t *testing.T) {
	t.Parallel()
	// No panic + creating a Service should succeed without explicit Tokens/Now.
	_ = sharing.New(sharing.Config{
		Repository:   newMemRepo(),
		Playthroughs: fakePlaythroughs{m: map[uuid.UUID]playthrough.Playthrough{}},
		Users:        fakeUsers{m: map[uuid.UUID]auth.User{}},
	})
}
