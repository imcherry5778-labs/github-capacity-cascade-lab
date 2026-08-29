package telemetry

import (
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type Metrics struct {
	// Default registry와 분리해 test/application instance별 metric이 섞이지 않게 한다.
	registry            *prometheus.Registry
	httpRequests        *prometheus.CounterVec
	httpRequestDuration *prometheus.HistogramVec
	inFlight            prometheus.Gauge
	faultInjections     *prometheus.CounterVec
	admissionRejections prometheus.Counter
}

func New() *Metrics {
	// Label은 고정 route, method, status class, fault kind로 제한해 cardinality가 입력 수에 따라 늘지 않게 한다.
	metrics := &Metrics{
		registry: prometheus.NewRegistry(),
		httpRequests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "capacity_cascade_http_requests_total",
			Help: "Total public HTTP requests handled by fixed route, method, and status class.",
		}, []string{"route", "method", "status_class"}),
		httpRequestDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "capacity_cascade_http_request_duration_seconds",
			Help:    "Public HTTP request duration by fixed route, method, and status class.",
			Buckets: prometheus.DefBuckets,
		}, []string{"route", "method", "status_class"}),
		inFlight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "capacity_cascade_http_in_flight",
			Help: "Token requests admitted and currently executing.",
		}),
		faultInjections: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "capacity_cascade_fault_injections_total",
			Help: "Applied token fault actions by bounded kind.",
		}, []string{"kind"}),
		admissionRejections: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "capacity_cascade_admission_rejections_total",
			Help: "Token requests rejected immediately by the application admission limit.",
		}),
	}
	metrics.registry.MustRegister(
		metrics.httpRequests,
		metrics.httpRequestDuration,
		metrics.inFlight,
		metrics.faultInjections,
		metrics.admissionRejections,
		prometheus.NewGoCollector(),
		prometheus.NewProcessCollector(prometheus.ProcessCollectorOpts{}),
	)
	// Fault가 없는 baseline에서도 두 bounded series가 /metrics에 노출되게 미리 생성한다.
	metrics.faultInjections.WithLabelValues("latency").Add(0)
	metrics.faultInjections.WithLabelValues("error").Add(0)
	return metrics
}

func (m *Metrics) ObserveHTTP(route, method, statusClass string, duration time.Duration) {
	m.httpRequests.WithLabelValues(route, method, statusClass).Inc()
	m.httpRequestDuration.WithLabelValues(route, method, statusClass).Observe(duration.Seconds())
}

func (m *Metrics) IncInFlight() {
	m.inFlight.Inc()
}

func (m *Metrics) DecInFlight() {
	m.inFlight.Dec()
}

func (m *Metrics) IncFault(kind string) {
	m.faultInjections.WithLabelValues(kind).Inc()
}

func (m *Metrics) IncAdmissionRejection() {
	m.admissionRejections.Inc()
}

func (m *Metrics) Handler() http.Handler {
	// 별도 registry만 exposition해 프로세스 전역 metric 오염을 막는다.
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{})
}
