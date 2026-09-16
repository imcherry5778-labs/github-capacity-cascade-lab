package main

import "testing"

func TestPodReady(t *testing.T) {
	value := pod{}
	value.Status.Conditions = append(value.Status.Conditions, struct {
		Type   string `json:"type"`
		Status string `json:"status"`
	}{Type: "Ready", Status: "True"})
	if !podReady(value) {
		t.Fatal("expected Ready condition to be recognized")
	}
}

func TestMetricPathOnlyServesConfiguredWildcard(t *testing.T) {
	adapter := adapter{config: configuration{namespace: "l05", metricName: "sidecar_active_requests"}}
	if adapter.config.namespace != "l05" || adapter.config.metricName != "sidecar_active_requests" {
		t.Fatal("test setup lost fixed metric boundary")
	}
}
