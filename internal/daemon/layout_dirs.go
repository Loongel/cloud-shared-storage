package daemon

import "cs-storage/internal/volume"

func layoutDirsFor(meta volume.Metadata, layout Layout) []string {
	dirs := []string{layout.Root, layout.Cache, layout.Logs, layout.Config}
	plan := PlanPipeline(meta.Options)
	if plan.RealtimeRclone {
		if meta.Options.Crypt {
			return appendUniqueDirs(dirs, layout.Remote, layout.Mountpoint)
		}
		return appendUniqueDirs(dirs, layout.Mountpoint)
	}
	switch plan.Kind {
	case PipelineSharedSQLite:
		dirs = appendUniqueDirs(dirs, layout.Mountpoint, layout.LiteFSData)
	case PipelineSharedStatic:
		dirs = appendUniqueDirs(dirs, layout.Mountpoint)
	case PipelineSharedAuto:
		dirs = appendUniqueDirs(dirs, layout.Mountpoint, layout.LiteFSData, layout.LiteFSMount, layout.Gluster)
	default:
		dirs = appendUniqueDirs(dirs, layout.Mountpoint)
	}
	if meta.Options.Crypt {
		dirs = appendUniqueDirs(dirs, layout.Remote)
	}
	return dirs
}

func appendUniqueDirs(dirs []string, more ...string) []string {
	for _, dir := range more {
		if dir == "" {
			continue
		}
		seen := false
		for _, existing := range dirs {
			if existing == dir {
				seen = true
				break
			}
		}
		if !seen {
			dirs = append(dirs, dir)
		}
	}
	return dirs
}
