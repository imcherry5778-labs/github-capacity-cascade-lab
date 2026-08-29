package fault

import (
	"context"
	"encoding/binary"
	"hash/fnv"
	"sync/atomic"
	"time"
)

type Limiter struct {
	inFlight atomic.Int64
}

func (l *Limiter) TryAcquire(limit int64) bool {
	if limit == 0 {
		l.inFlight.Add(1)
		return true
	}

	for {
		current := l.inFlight.Load()
		if current >= limit {
			return false
		}
		if l.inFlight.CompareAndSwap(current, current+1) {
			return true
		}
	}
}

func (l *Limiter) Release() {
	l.inFlight.Add(-1)
}

func (l *Limiter) InFlight() int64 {
	return l.inFlight.Load()
}

func Wait(ctx context.Context, delay time.Duration) error {
	if delay <= 0 {
		return nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()

	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func ShouldError(seed int64, requestID string, attempt int64, rate float64) bool {
	if rate <= 0 {
		return false
	}
	if rate >= 1 {
		return true
	}

	hasher := fnv.New64a()
	var encoded [8]byte
	binary.LittleEndian.PutUint64(encoded[:], uint64(seed))
	_, _ = hasher.Write(encoded[:])
	_, _ = hasher.Write([]byte{0})
	_, _ = hasher.Write([]byte(requestID))
	_, _ = hasher.Write([]byte{0})
	binary.LittleEndian.PutUint64(encoded[:], uint64(attempt))
	_, _ = hasher.Write(encoded[:])

	const denominator = float64(uint64(1) << 53)
	value := float64(hasher.Sum64()>>11) / denominator
	return value < rate
}
