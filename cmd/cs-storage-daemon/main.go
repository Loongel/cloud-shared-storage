package main

import (
	"log"
	"time"

	"cs-storage/internal/config"
	"cs-storage/internal/daemon"
)

func main() {
	srv, err := daemon.New(daemon.Config{
		ServerURL:             config.String("CS_SERVER_URL", ""),
		NodeID:                config.String("CS_NODE_ID", ""),
		NodeSecret:            config.String("CS_NODE_SECRET_KEY", ""),
		RcloneEndpoint:        config.String("CS_RCLONE_ENDPOINT", ""),
		RcloneBinary:          config.String("CS_RCLONE_BINARY", "rclone"),
		RcloneVFSCacheMode:    config.String("CS_RCLONE_VFS_CACHE_MODE", "writes"),
		RcloneVFSWriteBack:    config.String("CS_RCLONE_VFS_WRITE_BACK", ""),
		RcloneVFSCacheMaxSize: config.String("CS_RCLONE_VFS_CACHE_MAX_SIZE", ""),
		RcloneDirCacheTime:    config.String("CS_RCLONE_DIR_CACHE_TIME", "2s"),
		RcloneExtraArgs:       config.String("CS_RCLONE_EXTRA_ARGS", ""),
		RcloneSyncInterval:    config.Duration("CS_RCLONE_SYNC_INTERVAL", 0),
		RcloneSyncSource:      config.String("CS_RCLONE_SYNC_SOURCE", ""),
		RcloneSyncTarget:      config.String("CS_RCLONE_SYNC_TARGET", ""),
		GocryptfsBinary:       config.String("CS_GOCRYPTFS_BINARY", "gocryptfs"),
		GocryptfsPassword:     config.String("CS_GOCRYPTFS_PASSWORD", ""),
		GocryptfsExtraArgs:    config.String("CS_GOCRYPTFS_EXTRA_ARGS", ""),
		GlusterBinary:         config.String("CS_GLUSTER_BINARY", "mount.glusterfs"),
		GlusterRemote:         config.String("CS_GLUSTER_REMOTE", ""),
		GlusterExtraArgs:      config.String("CS_GLUSTER_EXTRA_ARGS", ""),
		LiteFSBinary:          config.String("CS_LITEFS_BINARY", ""),
		LiteFSConfig:          config.String("CS_LITEFS_CONFIG", ""),
		LiteFSHTTPAddr:        config.String("CS_LITEFS_HTTP_ADDR", ":20202"),
		LiteFSLeaseType:       config.String("CS_LITEFS_LEASE_TYPE", "static"),
		LiteFSAdvertiseURL:    config.String("CS_LITEFS_ADVERTISE_URL", ""),
		LiteFSConsulURL:       config.String("CS_LITEFS_CONSUL_URL", ""),
		LiteFSConsulKey:       config.String("CS_LITEFS_CONSUL_KEY", ""),
		LiteFSConsulTTL:       config.String("CS_LITEFS_CONSUL_TTL", "10s"),
		LiteFSConsulLockDelay: config.String("CS_LITEFS_CONSUL_LOCK_DELAY", "1s"),
		LiteFSHostname:        config.String("CS_LITEFS_HOSTNAME", ""),
		LiteFSPromote:         config.Bool("CS_LITEFS_PROMOTE", false),
		LiteFSConsulToken:     config.String("CS_LITEFS_CONSUL_TOKEN", ""),
		LiteFSCandidate:       config.Bool("CS_LITEFS_CANDIDATE", true),
		KopiaBinary:           config.String("CS_KOPIA_BINARY", ""),
		KopiaRepository:       config.String("CS_KOPIA_REPOSITORY", ""),
		KopiaConfigPath:       config.String("CS_KOPIA_CONFIG_PATH", ""),
		KopiaPassword:         config.String("CS_KOPIA_PASSWORD", ""),
		KopiaExtraArgs:        config.String("CS_KOPIA_EXTRA_ARGS", ""),
		KopiaPolicyArgs:       config.String("CS_KOPIA_POLICY_ARGS", ""),
		KopiaSnapshotInterval: config.Duration("CS_KOPIA_SNAPSHOT_INTERVAL", time.Hour),
		RouterBinary:          config.String("CS_ROUTER_BINARY", "cs-storage-router"),
		RouterExtraArgs:       config.String("CS_ROUTER_EXTRA_ARGS", ""),
		SocketPath:            config.String("CS_DAEMON_SOCKET", "/run/cs-storage.sock"),
		RootDir:               config.String("CS_ROOT_DIR", "/mnt/cs_storage/vols"),
		StatePath:             config.String("CS_STATE_PATH", ""),
		AuditLogPath:          config.String("CS_AUDIT_LOG", ""),
		RcloneRCAddr:          config.String("CS_RCLONE_RC_ADDR", ""),
		RcloneRCUser:          config.String("CS_RCLONE_RC_USER", ""),
		RcloneRCPassword:      config.String("CS_RCLONE_RC_PASSWORD", ""),
		EnableChattr:          config.Bool("CS_ENABLE_CHATTR", false),
		RecoverMounts:         config.Bool("CS_RECOVER_MOUNTS", false),
		ManagedVolumes:        config.String("CS_MANAGED_VOLUMES", config.String("CS_PREMOUNT_VOLUMES", "")),
		ManagedEnsureInterval: config.Duration("CS_MANAGED_ENSURE_INTERVAL", 30*time.Second),
	})
	if err != nil {
		log.Fatal(err)
	}
	log.Fatal(srv.ListenAndServe())
}
