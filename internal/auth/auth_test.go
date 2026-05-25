package auth

import (
	"testing"
	"time"
)

func TestTokenRoundTrip(t *testing.T) {
	claims := Claims{NodeID: "node-a", Sandbox: "/nodes/node-a", Expiration: time.Now().Add(time.Hour).Unix()}
	token, err := IssueToken("secret", claims)
	if err != nil {
		t.Fatal(err)
	}
	got, err := VerifyToken("secret", token)
	if err != nil {
		t.Fatal(err)
	}
	if got.NodeID != claims.NodeID || got.Sandbox != claims.Sandbox {
		t.Fatalf("claims mismatch: %#v", got)
	}
}

func TestNodeAuthSignature(t *testing.T) {
	ts := time.Now().Unix()
	sig := SignNodeAuth("secret", "node-a", ts)
	if !VerifyNodeAuth("secret", "node-a", ts, sig, time.Minute) {
		t.Fatal("valid signature rejected")
	}
	if VerifyNodeAuth("secret", "node-b", ts, sig, time.Minute) {
		t.Fatal("signature accepted for wrong node")
	}
}
