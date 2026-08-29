package fault

import (
	"context"
	"testing"
	"time"
)

func TestShouldErrorDeterministic(t *testing.T) {
	tests := []struct {
		name string
		rate float64
		want bool
	}{
		{name: "zero", rate: 0, want: false},
		{name: "one", rate: 1, want: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := ShouldError(DefaultSeed, "logical-1", 1, test.rate); got != test.want {
				t.Fatalf("ShouldError() = %v, want %v", got, test.want)
			}
		})
	}

	first := ShouldError(DefaultSeed, "logical-1", 2, 0.5)
	for range 100 {
		if got := ShouldError(DefaultSeed, "logical-1", 2, 0.5); got != first {
			t.Fatalf("same inputs changed decision: first=%v got=%v", first, got)
		}
	}
}

func TestWaitHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	started := time.Now()
	err := Wait(ctx, time.Second)
	if err == nil {
		t.Fatal("Wait() error = nil, want cancellation")
	}
	if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
		t.Fatalf("Wait() took %v after cancellation", elapsed)
	}
}

func TestLimiterRejectsWithoutQueueing(t *testing.T) {
	var limiter Limiter
	if !limiter.TryAcquire(1) {
		t.Fatal("first TryAcquire() rejected")
	}
	started := time.Now()
	if limiter.TryAcquire(1) {
		t.Fatal("second TryAcquire() accepted")
	}
	if elapsed := time.Since(started); elapsed > 50*time.Millisecond {
		t.Fatalf("rejection took %v", elapsed)
	}
	limiter.Release()
	if got := limiter.InFlight(); got != 0 {
		t.Fatalf("InFlight() = %d, want 0", got)
	}
}
