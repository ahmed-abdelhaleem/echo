package auth

import "testing"

func TestNewReturnsService(t *testing.T) {
	t.Parallel()
	got := New(nil)
	if got == nil {
		t.Fatal("New returned nil")
	}
	if got.Kratos != nil {
		t.Errorf("expected Kratos to be nil when constructed with nil; got %v", got.Kratos)
	}
}
