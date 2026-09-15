package main

import "testing"

func TestParsersReadSelectedProxyAndApplicationSignals(t *testing.T) {
	proxy := parseProxyStats(`cluster.inbound|8080||;.upstream_rq_active: 1
cluster.inbound|8080||;.upstream_rq_total: 8
cluster.inbound|8080||;.upstream_rq_active_overflow: 6
cluster.inbound|8080||;.upstream_rq_pending_overflow: 2
cluster.inbound|8080||;.upstream_rq_retry: 0
cluster.inbound|8080||;.upstream_rq_timeout: 0
http.inbound_10.42.0.9_8080;.downstream_rq_total: 14
http.inbound_10.42.0.9_8080;.downstream_rq_5xx: 6
`)
	if proxy.UpstreamActive != 1 || proxy.ActiveOverflow != 6 || proxy.Downstream5xx != 6 {
		t.Fatalf("unexpected proxy snapshot: %#v", proxy)
	}
	app := parseAppMetrics(`capacity_cascade_http_in_flight 1
capacity_cascade_admission_rejections_total 0
capacity_cascade_http_requests_total{method="POST",route="/token",status_class="2xx"} 8
`)
	if app.InFlight != 1 || app.TokenRequests != 8 || app.AdmissionRejections != 0 {
		t.Fatalf("unexpected application snapshot: %#v", app)
	}
}
