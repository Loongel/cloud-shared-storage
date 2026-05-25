package config

import (
	"os"
	"strconv"
	"strings"
	"time"
)

func String(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	if path := os.Getenv(key + "_FILE"); path != "" {
		if b, err := os.ReadFile(path); err == nil {
			return strings.TrimRight(string(b), "\r\n")
		}
	}
	return fallback
}

func Bool(key string, fallback bool) bool {
	v := String(key, "")
	if v == "" {
		return fallback
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return fallback
	}
	return b
}

func Duration(key string, fallback time.Duration) time.Duration {
	v := String(key, "")
	if v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return fallback
	}
	return d
}
