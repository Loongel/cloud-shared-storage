package daemon

import (
	"testing"

	"cs-storage/internal/volume"
)

func TestMountRefs(t *testing.T) {
	meta := volume.Metadata{Name: "vol"}
	addMountRef(&meta, "a")
	addMountRef(&meta, "b")
	if !hasMountRefs(meta) || len(meta.MountIDs) != 2 {
		t.Fatalf("unexpected refs after add: %#v", meta.MountIDs)
	}
	removeMountRef(&meta, "a")
	if !hasMountRefs(meta) || len(meta.MountIDs) != 1 {
		t.Fatalf("unexpected refs after removing one: %#v", meta.MountIDs)
	}
	removeMountRef(&meta, "b")
	if hasMountRefs(meta) {
		t.Fatalf("expected no refs: %#v", meta.MountIDs)
	}
}
