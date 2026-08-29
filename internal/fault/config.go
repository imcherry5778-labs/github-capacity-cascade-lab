package fault

import (
	"fmt"
	"sync/atomic"
)

const (
	MaxLatencyMS int64 = 60_000
	MaxInFlight  int64 = 1_000_000
	DefaultSeed  int64 = 17_082_026
)

// Config는 저장된 후 변경되지 않는 장애 주입 설정 스냅샷이다.
type Config struct {
	LatencyMS   int64   `json:"latency_ms"`
	ErrorRate   float64 `json:"error_rate"`
	MaxInFlight int64   `json:"max_in_flight"`
	Seed        int64   `json:"seed"`
}

func DefaultConfig() Config {
	return Config{Seed: DefaultSeed}
}

func (c Config) Validate() error {
	if c.LatencyMS < 0 || c.LatencyMS > MaxLatencyMS {
		return fmt.Errorf("latency_ms must be between 0 and %d", MaxLatencyMS)
	}
	if c.ErrorRate < 0 || c.ErrorRate > 1 {
		return fmt.Errorf("error_rate must be between 0.0 and 1.0")
	}
	if c.MaxInFlight < 0 || c.MaxInFlight > MaxInFlight {
		return fmt.Errorf("max_in_flight must be between 0 and %d", MaxInFlight)
	}
	return nil
}

type Store struct {
	value atomic.Pointer[Config]
}

func NewStore(initial Config) (*Store, error) {
	if err := initial.Validate(); err != nil {
		return nil, err
	}
	store := &Store{}
	store.value.Store(&initial)
	return store, nil
}

func (s *Store) Load() Config {
	return *s.value.Load()
}

func (s *Store) Update(next Config) error {
	if err := next.Validate(); err != nil {
		return err
	}
	s.value.Store(&next)
	return nil
}
