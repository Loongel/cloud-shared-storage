package daemon

import "cs-storage/internal/volume"

func mountID(id string) string {
	if id == "" {
		return "default"
	}
	return id
}

func addMountRef(meta *volume.Metadata, id string) {
	if meta.MountIDs == nil {
		meta.MountIDs = map[string]bool{}
	}
	meta.MountIDs[mountID(id)] = true
}

func removeMountRef(meta *volume.Metadata, id string) {
	if meta.MountIDs == nil {
		return
	}
	delete(meta.MountIDs, mountID(id))
}

func hasMountRefs(meta volume.Metadata) bool {
	return len(meta.MountIDs) > 0
}
