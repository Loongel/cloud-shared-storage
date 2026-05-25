package main

import (
	"log"
	"time"

	"cs-storage/internal/config"
	"cs-storage/internal/plugin"
)

func main() {
	srv := plugin.New(plugin.Config{
		SocketPath:   config.String("CS_PLUGIN_SOCKET", "/run/docker/plugins/css.sock"),
		DaemonUDS:    config.String("CS_DAEMON_SOCKET", "/run/cs-storage.sock"),
		DockerSocket: config.String("CS_DOCKER_SOCKET", "/var/run/docker.sock"),
		Scope:        config.String("CS_PLUGIN_SCOPE", "local"),
		Timeout:      config.Duration("CS_PLUGIN_TIMEOUT", 5*time.Second),
	})
	log.Fatal(srv.ListenAndServe())
}
