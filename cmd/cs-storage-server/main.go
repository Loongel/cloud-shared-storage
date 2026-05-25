package main

import (
	"log"
	"time"

	"cs-storage/internal/config"
	"cs-storage/internal/gateway"
)

func main() {
	cfg := gateway.Config{
		Addr:              config.String("CS_SERVER_ADDR", ":8080"),
		Secret:            config.String("CS_NODE_SECRET_KEY", ""),
		BackendURL:        config.String("CS_BACKEND_URL", ""),
		BackendAuthHeader: config.String("CS_BACKEND_AUTH_HEADER", ""),
		BackendUser:       config.String("CS_BACKEND_USER", ""),
		BackendPassword:   config.String("CS_BACKEND_PASSWORD", ""),
		TokenTTL:          config.Duration("CS_TOKEN_TTL", 12*time.Hour),
		SandboxPrefix:     config.String("CS_SANDBOX_PREFIX", "/nodes"),
		KVPath:            config.String("CS_KV_PATH", ""),
		CoordinatorToken:  config.String("CS_COORDINATOR_TOKEN", ""),
		PublicURL:         config.String("CS_PUBLIC_URL", ""),
	}
	if cfg.Secret == "" || cfg.BackendURL == "" {
		log.Fatal("CS_NODE_SECRET_KEY and CS_BACKEND_URL are required")
	}
	srv, err := gateway.New(cfg)
	if err != nil {
		log.Fatal(err)
	}
	log.Fatal(srv.ListenAndServe())
}
