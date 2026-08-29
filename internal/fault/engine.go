package fault

import (
	"context"
	"encoding/binary"
	"hash/fnv"
	"sync/atomic"
	"time"
)

type Limiter struct {
	// L00의 application 입장 제한이며 Istio sidecar concurrency 구현이 아니다.
	inFlight atomic.Int64
}

func (l *Limiter) TryAcquire(limit int64) bool {
	// 0은 unlimited다. 제한에 도달하면 queue에서 기다리지 않고 즉시 거절한다.
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
	// 요청이 취소되면 주입한 latency 전체를 기다리지 않고 빠르게 종료한다.
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
	// 시간에 따라 바뀌는 random 장애가 아니라, 같은 입력에 항상 같은 결과를 내는 비교용 profile이다.
	// GitHub의 실제 error 알고리즘을 복제한 것이 아니다.
	if rate <= 0 {
		return false
	}
	if rate >= 1 {
		return true
	}

	hasher := fnv.New64a()
	var encoded [8]byte
	// 0 byte로 필드를 구분해 서로 다른 seed, request ID, attempt 조합이 섞이지 않게 한다.
	binary.LittleEndian.PutUint64(encoded[:], uint64(seed))
	_, _ = hasher.Write(encoded[:])
	_, _ = hasher.Write([]byte{0})
	_, _ = hasher.Write([]byte(requestID))
	_, _ = hasher.Write([]byte{0})
	binary.LittleEndian.PutUint64(encoded[:], uint64(attempt))
	_, _ = hasher.Write(encoded[:])

	// Hash를 0 이상 1 미만으로 변환해 설정한 error rate와 비교한다.
	const denominator = float64(uint64(1) << 53)
	value := float64(hasher.Sum64()>>11) / denominator
	return value < rate
}
