// proxy-metrics-exporter exposes a deliberately small, pod-local observation
// surface for L05. It reads Envoy's loopback-only admin interface and
// auth-sim's local metrics endpoint; neither endpoint is added to the public
// Service.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultListenAddr = ":18081"
	proxyStatsURL     = "http://127.0.0.1:15000/stats?filter=8080"
	appMetricsURL     = "http://127.0.0.1:8080/metrics"
)

type snapshot struct {
	TimestampUTC string        `json:"timestamp_utc"`
	Proxy        proxySnapshot `json:"proxy"`
	Application  appSnapshot   `json:"application"`
}

type proxySnapshot struct {
	UpstreamActive  int64 `json:"upstream_active"`
	UpstreamTotal   int64 `json:"upstream_total"`
	ActiveOverflow  int64 `json:"active_overflow"`
	PendingOverflow int64 `json:"pending_overflow"`
	Retry           int64 `json:"retry"`
	Timeout         int64 `json:"timeout"`
	DownstreamTotal int64 `json:"downstream_total"`
	Downstream5xx   int64 `json:"downstream_5xx"`
}

type appSnapshot struct {
	InFlight            int64 `json:"in_flight"`
	TokenRequests       int64 `json:"token_requests"`
	AdmissionRejections int64 `json:"admission_rejections"`
}

type exporter struct {
	client        *http.Client
	proxyStatsURL string
	appMetricsURL string
}

func main() {
	listenAddr := envOrDefault("PROXY_METRICS_EXPORTER_ADDR", defaultListenAddr)
	exporter := exporter{
		client:        &http.Client{Timeout: 2 * time.Second},
		proxyStatsURL: envOrDefault("PROXY_STATS_URL", proxyStatsURL),
		appMetricsURL: envOrDefault("APPLICATION_METRICS_URL", appMetricsURL),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("GET /snapshot", exporter.handleSnapshot)

	server := &http.Server{
		Addr:              listenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 2 * time.Second,
	}
	log.Printf("L05 proxy metrics exporter listening on %s", listenAddr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func (e exporter) handleSnapshot(w http.ResponseWriter, r *http.Request) {
	value, err := e.collect(r.Context())
	if err != nil {
		http.Error(w, fmt.Sprintf("observation unavailable: %v", err), http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("write snapshot: %v", err)
	}
}

func (e exporter) collect(ctx context.Context) (snapshot, error) {
	proxyText, err := e.getText(ctx, e.proxyStatsURL)
	if err != nil {
		return snapshot{}, fmt.Errorf("proxy stats: %w", err)
	}
	appText, err := e.getText(ctx, e.appMetricsURL)
	if err != nil {
		return snapshot{}, fmt.Errorf("application metrics: %w", err)
	}
	return snapshot{
		TimestampUTC: time.Now().UTC().Format(time.RFC3339Nano),
		Proxy:        parseProxyStats(proxyText),
		Application:  parseAppMetrics(appText),
	}, nil
}

func (e exporter) getText(ctx context.Context, url string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	response, err := e.client.Do(req)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("unexpected status %s", response.Status)
	}
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return "", err
	}
	return string(body), nil
}

func parseProxyStats(text string) proxySnapshot {
	values := make(map[string]int64)
	for _, line := range strings.Split(text, "\n") {
		name, rawValue, found := strings.Cut(line, ": ")
		if !found {
			continue
		}
		value, err := strconv.ParseInt(strings.TrimSpace(rawValue), 10, 64)
		if err == nil {
			values[name] = value
		}
	}
	return proxySnapshot{
		UpstreamActive:  statBySuffix(values, "cluster.inbound|8080||", ".upstream_rq_active"),
		UpstreamTotal:   statBySuffix(values, "cluster.inbound|8080||", ".upstream_rq_total"),
		ActiveOverflow:  statBySuffix(values, "cluster.inbound|8080||", ".upstream_rq_active_overflow"),
		PendingOverflow: statBySuffix(values, "cluster.inbound|8080||", ".upstream_rq_pending_overflow"),
		Retry:           statBySuffix(values, "cluster.inbound|8080||", ".upstream_rq_retry"),
		Timeout:         statBySuffix(values, "cluster.inbound|8080||", ".upstream_rq_timeout"),
		DownstreamTotal: statBySuffix(values, "http.inbound", ".downstream_rq_total"),
		Downstream5xx:   statBySuffix(values, "http.inbound", ".downstream_rq_5xx"),
	}
}

func statBySuffix(values map[string]int64, prefix, suffix string) int64 {
	for name, value := range values {
		if strings.HasPrefix(name, prefix) && strings.HasSuffix(name, suffix) {
			return value
		}
	}
	return 0
}

func parseAppMetrics(text string) appSnapshot {
	var result appSnapshot
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 2 {
			continue
		}
		value, err := strconv.ParseFloat(fields[1], 64)
		if err != nil {
			continue
		}
		switch {
		case fields[0] == "capacity_cascade_http_in_flight":
			result.InFlight += int64(value)
		case fields[0] == "capacity_cascade_admission_rejections_total":
			result.AdmissionRejections += int64(value)
		case strings.HasPrefix(fields[0], "capacity_cascade_http_requests_total{") && strings.Contains(fields[0], `route="/token"`):
			result.TokenRequests += int64(value)
		}
	}
	return result
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
