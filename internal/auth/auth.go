package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

var b64 = base64.RawURLEncoding

type Claims struct {
	NodeID     string `json:"node_id"`
	Sandbox    string `json:"sandbox"`
	Mode       string `json:"mode,omitempty"`
	Engine     string `json:"engine,omitempty"`
	Expiration int64  `json:"exp"`
}

func SignNodeAuth(secret, nodeID string, ts int64) string {
	mac := hmac.New(sha256.New, []byte(secret))
	fmt.Fprintf(mac, "%s\n%d", nodeID, ts)
	return hex.EncodeToString(mac.Sum(nil))
}

func VerifyNodeAuth(secret, nodeID string, ts int64, signature string, skew time.Duration) bool {
	if nodeID == "" || signature == "" {
		return false
	}
	now := time.Now().Unix()
	if ts < now-int64(skew.Seconds()) || ts > now+int64(skew.Seconds()) {
		return false
	}
	expected := SignNodeAuth(secret, nodeID, ts)
	return hmac.Equal([]byte(expected), []byte(strings.ToLower(signature)))
}

func IssueToken(secret string, claims Claims) (string, error) {
	header := map[string]string{"alg": "HS256", "typ": "JWT"}
	h, err := json.Marshal(header)
	if err != nil {
		return "", err
	}
	p, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	unsigned := b64.EncodeToString(h) + "." + b64.EncodeToString(p)
	sig := signJWT(secret, unsigned)
	return unsigned + "." + sig, nil
}

func VerifyToken(secret, token string) (Claims, error) {
	var claims Claims
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return claims, errors.New("invalid token format")
	}
	unsigned := parts[0] + "." + parts[1]
	if !hmac.Equal([]byte(signJWT(secret, unsigned)), []byte(parts[2])) {
		return claims, errors.New("invalid token signature")
	}
	payload, err := b64.DecodeString(parts[1])
	if err != nil {
		return claims, err
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return claims, err
	}
	if claims.NodeID == "" || claims.Sandbox == "" {
		return claims, errors.New("missing required claims")
	}
	if claims.Expiration <= time.Now().Unix() {
		return claims, errors.New("token expired")
	}
	return claims, nil
}

func signJWT(secret, unsigned string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(unsigned))
	return b64.EncodeToString(mac.Sum(nil))
}
