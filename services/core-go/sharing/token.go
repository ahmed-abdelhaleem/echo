package sharing

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
)

// shareTokenBytes is the random byte length used to mint share tokens.
// 16 bytes of crypto/rand encoded to base64-urlsafe (no padding) yields
// a 22-character string with ~128 bits of entropy. 22 chars fits
// comfortably in a URL, in a SMS, and in a QR code, while still being
// well above the brute-force threshold for online enumeration.
const shareTokenBytes = 16

// cryptoTokenSource generates tokens with crypto/rand. This is the
// production TokenSource.
type cryptoTokenSource struct{}

// NewTokenSource returns the production crypto/rand-backed TokenSource.
func NewTokenSource() TokenSource {
	return cryptoTokenSource{}
}

// NewToken mints a fresh ≥128-bit base64-urlsafe token.
func (cryptoTokenSource) NewToken() (string, error) {
	buf := make([]byte, shareTokenBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("sharing: token: rand: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}
