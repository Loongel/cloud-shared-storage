package daemon

import "cs-storage/internal/volume"

type PipelineKind string

const (
	PipelinePrivateRclone PipelineKind = "private-rclone"
	PipelineSharedSingle  PipelineKind = "shared-single-rclone"
	PipelineSharedStatic  PipelineKind = "shared-multi-gluster"
	PipelineSharedSQLite  PipelineKind = "shared-multi-litefs"
	PipelineSharedAuto    PipelineKind = "shared-multi-auto"
)

type Pipeline struct {
	Kind           PipelineKind `json:"kind"`
	Components     []string     `json:"components"`
	RealtimeRclone bool         `json:"realtime_rclone"`
	PeriodicSync   bool         `json:"periodic_sync"`
	NeedsRouter    bool         `json:"needs_router"`
	NeedsLiteFS    bool         `json:"needs_litefs"`
	NeedsGluster   bool         `json:"needs_gluster"`
	NeedsCrypt     bool         `json:"needs_crypt"`
	NeedsBackup    bool         `json:"needs_backup"`
}

func PlanPipeline(opts volume.Options) Pipeline {
	p := Pipeline{NeedsCrypt: opts.Crypt, NeedsBackup: opts.Backup == "auto"}
	if opts.Mode == "private" {
		p.Kind = PipelinePrivateRclone
		p.RealtimeRclone = true
		p.Components = append(p.Components, "docker", "volume-plugin", "daemon")
		appendCryptAndRclone(&p)
		return p
	}
	if opts.Write == "single" {
		p.Kind = PipelineSharedSingle
		p.RealtimeRclone = true
		p.Components = append(p.Components, "docker", "volume-plugin", "daemon")
		appendCryptAndRclone(&p)
		return p
	}
	p.PeriodicSync = true
	switch opts.Engine {
	case "static":
		p.Kind = PipelineSharedStatic
		p.NeedsGluster = true
		p.Components = append(p.Components, "docker", "volume-plugin", "daemon", "glusterfs")
	case "sqlite":
		p.Kind = PipelineSharedSQLite
		p.NeedsLiteFS = true
		p.Components = append(p.Components, "docker", "volume-plugin", "daemon", "litefs")
	default:
		p.Kind = PipelineSharedAuto
		p.NeedsRouter = true
		p.NeedsLiteFS = true
		p.NeedsGluster = true
		p.Components = append(p.Components, "docker", "volume-plugin", "daemon", "gofuse-router", "litefs", "glusterfs")
	}
	if p.NeedsCrypt {
		p.Components = append(p.Components, "gocryptfs")
	}
	p.Components = append(p.Components, "local-disk", "rclone-sync", "server-gateway")
	if p.NeedsBackup {
		p.Components = append(p.Components, "kopia")
	}
	return p
}

func appendCryptAndRclone(p *Pipeline) {
	if p.NeedsCrypt {
		p.Components = append(p.Components, "gocryptfs")
	}
	p.Components = append(p.Components, "rclone-vfs", "server-gateway")
	if p.NeedsBackup {
		p.Components = append(p.Components, "kopia")
	}
}
