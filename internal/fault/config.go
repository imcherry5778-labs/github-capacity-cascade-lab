package fault

import (
	"fmt"
	"sync/atomic"
)

const (
	// 상한은 실수로 과도한 local fault를 주입하는 것을 막는 L00 안전 경계다.
	MaxLatencyMS int64 = 60_000
	MaxInFlight  int64 = 1_000_000
	DefaultSeed  int64 = 17_082_026
)

// Config는 저장된 후 변경되지 않는 장애 주입 설정 스냅샷이다.
// MaxInFlight가 0이면 application admission limit을 적용하지 않는다.
type Config struct {
	LatencyMS   int64   `json:"latency_ms"`
	ErrorRate   float64 `json:"error_rate"`
	MaxInFlight int64   `json:"max_in_flight"`
	Seed        int64   `json:"seed"`
}

func DefaultConfig() Config {
	// latency, error, admission limit이 모두 0인 정상 상태에 재현용 seed만 고정한다.
	return Config{Seed: DefaultSeed}
}

func (c Config) Validate() error {
	// Admin API로 들어온 실험 설정을 저장하기 전에 안전 범위로 제한한다.
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
	// 완성된 Config 포인터를 한 번에 교체해 요청이 일부만 바뀐 설정을 보지 않게 한다.
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
	// 완성된 snapshot 복사본을 반환하며, 요청 처리자는 시작 시점에 한 번만 읽어 사용한다.
	return *s.value.Load()
}

func (s *Store) Update(next Config) error {
	if err := next.Validate(); err != nil {
		return err
	}
	// Reader lock 없이 다음 완성된 snapshot으로 원자적으로 교체한다.
	s.value.Store(&next)
	return nil
}
