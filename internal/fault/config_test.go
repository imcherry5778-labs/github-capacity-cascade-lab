package fault

import (
	"sync"
	"testing"
)

func TestConfigValidate(t *testing.T) {
	tests := []struct {
		name    string
		config  Config
		wantErr bool
	}{
		{name: "default", config: DefaultConfig()},
		{name: "maximums", config: Config{LatencyMS: MaxLatencyMS, ErrorRate: 1, MaxInFlight: MaxInFlight}},
		{name: "negative latency", config: Config{LatencyMS: -1}, wantErr: true},
		{name: "excessive latency", config: Config{LatencyMS: MaxLatencyMS + 1}, wantErr: true},
		{name: "negative rate", config: Config{ErrorRate: -0.1}, wantErr: true},
		{name: "excessive rate", config: Config{ErrorRate: 1.1}, wantErr: true},
		{name: "negative limit", config: Config{MaxInFlight: -1}, wantErr: true},
		{name: "excessive limit", config: Config{MaxInFlight: MaxInFlight + 1}, wantErr: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := test.config.Validate()
			if (err != nil) != test.wantErr {
				t.Fatalf("Validate() error = %v, wantErr %v", err, test.wantErr)
			}
		})
	}
}

func TestStoreAtomicUpdate(t *testing.T) {
	first := Config{LatencyMS: 10, ErrorRate: 0.1, MaxInFlight: 1, Seed: 1}
	second := Config{LatencyMS: 20, ErrorRate: 0.2, MaxInFlight: 2, Seed: 2}
	store, err := NewStore(first)
	if err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	for range 4 {
		wg.Go(func() {
			for range 1_000 {
				got := store.Load()
				if got != first && got != second {
					t.Errorf("observed partial config: %+v", got)
					return
				}
			}
		})
	}
	for range 1_000 {
		if err := store.Update(second); err != nil {
			t.Fatal(err)
		}
		if err := store.Update(first); err != nil {
			t.Fatal(err)
		}
	}
	wg.Wait()
}
