package daemon

import (
	"testing"

	"cs-storage/internal/volume"
)

func TestPlanPipelinePrivateUsesRealtimeRclone(t *testing.T) {
	p := PlanPipeline(volume.Options{Mode: "private", Write: "single", Engine: "auto", Crypt: true})
	if p.Kind != PipelinePrivateRclone || !p.RealtimeRclone || p.PeriodicSync {
		t.Fatalf("unexpected private pipeline: %#v", p)
	}
}

func TestPlanPipelineSharedAutoUsesRouterLiteFSAndGluster(t *testing.T) {
	p := PlanPipeline(volume.Options{Mode: "shared", Write: "multi", Engine: "auto", Crypt: true})
	if p.Kind != PipelineSharedAuto || !p.NeedsRouter || !p.NeedsLiteFS || !p.NeedsGluster || !p.PeriodicSync {
		t.Fatalf("unexpected auto pipeline: %#v", p)
	}
}
