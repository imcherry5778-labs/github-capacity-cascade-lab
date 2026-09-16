// l05-custom-metrics-adapter is a bounded local aggregation API for the L05
// experiment. It implements only one per-Pod custom metric and one read-only
// snapshot endpoint; it is not a general monitoring system.
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const serviceAccountDirectory = "/var/run/secrets/kubernetes.io/serviceaccount"

type configuration struct {
	listenAddr     string
	namespace      string
	metricName     string
	podSelector    string
	exporterPort   string
	kubernetesHost string
	kubernetesPort string
	serviceAccount string
}

type adapter struct {
	config configuration
	client *http.Client
}

type podList struct {
	Items []pod `json:"items"`
}

type pod struct {
	Metadata struct {
		Name string `json:"name"`
	} `json:"metadata"`
	Status struct {
		Phase      string `json:"phase"`
		PodIP      string `json:"podIP"`
		Conditions []struct {
			Type   string `json:"type"`
			Status string `json:"status"`
		} `json:"conditions"`
	} `json:"status"`
}

type exporterSnapshot struct {
	TimestampUTC string `json:"timestamp_utc"`
	Proxy        struct {
		UpstreamActive  int64 `json:"upstream_active"`
		UpstreamTotal   int64 `json:"upstream_total"`
		ActiveOverflow  int64 `json:"active_overflow"`
		PendingOverflow int64 `json:"pending_overflow"`
		Retry           int64 `json:"retry"`
		Timeout         int64 `json:"timeout"`
		DownstreamTotal int64 `json:"downstream_total"`
		Downstream5xx   int64 `json:"downstream_5xx"`
	} `json:"proxy"`
	Application struct {
		InFlight            int64 `json:"in_flight"`
		TokenRequests       int64 `json:"token_requests"`
		AdmissionRejections int64 `json:"admission_rejections"`
	} `json:"application"`
}

type observedPod struct {
	Name     string           `json:"name"`
	PodIP    string           `json:"pod_ip"`
	Exporter exporterSnapshot `json:"exporter"`
}

type aggregateSnapshot struct {
	TimestampUTC string        `json:"timestamp_utc"`
	Pods         []observedPod `json:"pods"`
	Proxy        struct {
		UpstreamActive  int64 `json:"upstream_active"`
		UpstreamTotal   int64 `json:"upstream_total"`
		ActiveOverflow  int64 `json:"active_overflow"`
		PendingOverflow int64 `json:"pending_overflow"`
		Retry           int64 `json:"retry"`
		Timeout         int64 `json:"timeout"`
		DownstreamTotal int64 `json:"downstream_total"`
		Downstream5xx   int64 `json:"downstream_5xx"`
	} `json:"proxy"`
	Application struct {
		InFlight            int64 `json:"in_flight"`
		TokenRequests       int64 `json:"token_requests"`
		AdmissionRejections int64 `json:"admission_rejections"`
	} `json:"application"`
}

func main() {
	config := configuration{}
	flag.StringVar(&config.listenAddr, "listen-addr", envOrDefault("LISTEN_ADDR", ":8443"), "TLS listen address")
	flag.StringVar(&config.namespace, "target-namespace", os.Getenv("TARGET_NAMESPACE"), "namespace of the scaled workload")
	flag.StringVar(&config.metricName, "metric-name", envOrDefault("METRIC_NAME", "sidecar_active_requests"), "only custom metric to expose")
	flag.StringVar(&config.podSelector, "pod-selector", os.Getenv("POD_SELECTOR"), "label selector for workload Pods")
	flag.StringVar(&config.exporterPort, "exporter-port", envOrDefault("EXPORTER_PORT", "18081"), "pod-local exporter port")
	flag.Parse()
	if config.namespace == "" || config.podSelector == "" {
		log.Fatal("target-namespace and pod-selector are required")
	}
	config.kubernetesHost = envOrDefault("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc")
	config.kubernetesPort = envOrDefault("KUBERNETES_SERVICE_PORT_HTTPS", "443")
	config.serviceAccount = serviceAccountDirectory
	client, err := newKubernetesClient(config)
	if err != nil {
		log.Fatal(err)
	}
	instance := adapter{config: config, client: client}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", instance.handleHealth)
	mux.HandleFunc("GET /snapshot", instance.handleSnapshot)
	mux.HandleFunc("GET /apis/custom.metrics.k8s.io/v1beta2", instance.handleDiscovery)
	mux.HandleFunc("GET /apis/custom.metrics.k8s.io/v1beta2/", instance.handleDiscovery)
	mux.HandleFunc("GET /apis/custom.metrics.k8s.io/v1beta2/namespaces/{namespace}/pods/{pod}/{metric}", instance.handleMetric)

	certificate, err := selfSignedCertificate()
	if err != nil {
		log.Fatal(err)
	}
	server := &http.Server{Addr: config.listenAddr, Handler: mux, ReadHeaderTimeout: 2 * time.Second}
	listener, err := tls.Listen("tcp", config.listenAddr, &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12})
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("L05 custom metrics adapter listening on %s for namespace %s", config.listenAddr, config.namespace)
	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func (a adapter) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

func (a adapter) handleDiscovery(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"kind": "APIResourceList", "apiVersion": "v1", "groupVersion": "custom.metrics.k8s.io/v1beta2",
		"resources": []map[string]any{{"name": "pods/" + a.config.metricName, "singularName": "", "namespaced": true, "kind": "MetricValue", "verbs": []string{"get"}}},
	})
}

func (a adapter) handleSnapshot(w http.ResponseWriter, r *http.Request) {
	value, err := a.snapshot(r.Context())
	if err != nil {
		http.Error(w, fmt.Sprintf("snapshot unavailable: %v", err), http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, http.StatusOK, value)
}

func (a adapter) handleMetric(w http.ResponseWriter, r *http.Request) {
	if r.PathValue("namespace") != a.config.namespace || r.PathValue("metric") != a.config.metricName || r.PathValue("pod") != "*" {
		http.NotFound(w, r)
		return
	}
	value, err := a.snapshot(r.Context())
	if err != nil {
		http.Error(w, fmt.Sprintf("metric unavailable: %v", err), http.StatusServiceUnavailable)
		return
	}
	items := make([]map[string]any, 0, len(value.Pods))
	for _, observed := range value.Pods {
		items = append(items, map[string]any{
			"describedObject": map[string]string{"apiVersion": "v1", "kind": "Pod", "namespace": a.config.namespace, "name": observed.Name},
			"metric":          map[string]string{"name": a.config.metricName},
			"timestamp":       observed.Exporter.TimestampUTC,
			"value":           fmt.Sprintf("%dm", observed.Exporter.Proxy.UpstreamActive*1000),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"kind": "MetricValueList", "apiVersion": "custom.metrics.k8s.io/v1beta2", "metadata": map[string]any{}, "items": items})
}

func (a adapter) snapshot(ctx context.Context) (aggregateSnapshot, error) {
	pods, err := a.listReadyPods(ctx)
	if err != nil {
		return aggregateSnapshot{}, err
	}
	if len(pods) == 0 {
		return aggregateSnapshot{}, errors.New("no ready workload Pods")
	}
	result := aggregateSnapshot{TimestampUTC: time.Now().UTC().Format(time.RFC3339Nano)}
	for _, workloadPod := range pods {
		value, err := a.fetchExporter(ctx, workloadPod.Status.PodIP)
		if err != nil {
			return aggregateSnapshot{}, fmt.Errorf("exporter for %s: %w", workloadPod.Metadata.Name, err)
		}
		result.Pods = append(result.Pods, observedPod{Name: workloadPod.Metadata.Name, PodIP: workloadPod.Status.PodIP, Exporter: value})
		result.Proxy.UpstreamActive += value.Proxy.UpstreamActive
		result.Proxy.UpstreamTotal += value.Proxy.UpstreamTotal
		result.Proxy.ActiveOverflow += value.Proxy.ActiveOverflow
		result.Proxy.PendingOverflow += value.Proxy.PendingOverflow
		result.Proxy.Retry += value.Proxy.Retry
		result.Proxy.Timeout += value.Proxy.Timeout
		result.Proxy.DownstreamTotal += value.Proxy.DownstreamTotal
		result.Proxy.Downstream5xx += value.Proxy.Downstream5xx
		result.Application.InFlight += value.Application.InFlight
		result.Application.TokenRequests += value.Application.TokenRequests
		result.Application.AdmissionRejections += value.Application.AdmissionRejections
	}
	return result, nil
}

func (a adapter) listReadyPods(ctx context.Context) ([]pod, error) {
	path := fmt.Sprintf("/api/v1/namespaces/%s/pods?labelSelector=%s", url.PathEscape(a.config.namespace), url.QueryEscape(a.config.podSelector))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+a.config.kubernetesHost+":"+a.config.kubernetesPort+path, nil)
	if err != nil {
		return nil, err
	}
	response, err := a.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Pod list status %s", response.Status)
	}
	var listed podList
	if err := json.NewDecoder(response.Body).Decode(&listed); err != nil {
		return nil, err
	}
	ready := make([]pod, 0, len(listed.Items))
	for _, item := range listed.Items {
		if item.Status.Phase == "Running" && item.Status.PodIP != "" && podReady(item) {
			ready = append(ready, item)
		}
	}
	return ready, nil
}

func (a adapter) fetchExporter(ctx context.Context, podIP string) (exporterSnapshot, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+podIP+":"+a.config.exporterPort+"/snapshot", nil)
	if err != nil {
		return exporterSnapshot{}, err
	}
	response, err := (&http.Client{Timeout: 2 * time.Second}).Do(request)
	if err != nil {
		return exporterSnapshot{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return exporterSnapshot{}, fmt.Errorf("status %s", response.Status)
	}
	var result exporterSnapshot
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		return exporterSnapshot{}, err
	}
	if result.TimestampUTC == "" {
		return exporterSnapshot{}, errors.New("missing exporter timestamp")
	}
	return result, nil
}

func podReady(value pod) bool {
	for _, condition := range value.Status.Conditions {
		if condition.Type == "Ready" && condition.Status == "True" {
			return true
		}
	}
	return false
}

func newKubernetesClient(config configuration) (*http.Client, error) {
	token, err := os.ReadFile(filepath.Join(config.serviceAccount, "token"))
	if err != nil {
		return nil, fmt.Errorf("read service account token: %w", err)
	}
	caBytes, err := os.ReadFile(filepath.Join(config.serviceAccount, "ca.crt"))
	if err != nil {
		return nil, fmt.Errorf("read service account CA: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caBytes) {
		return nil, errors.New("service account CA did not contain a certificate")
	}
	return &http.Client{Timeout: 3 * time.Second, Transport: &bearerTransport{
		token: strings.TrimSpace(string(token)),
		base:  &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}},
	}}, nil
}

type bearerTransport struct {
	token string
	base  http.RoundTripper
}

func (t *bearerTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	clone := request.Clone(request.Context())
	clone.Header.Set("Authorization", "Bearer "+t.token)
	return t.base.RoundTrip(clone)
}

func selfSignedCertificate() (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}
	now := time.Now()
	template := x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "l05-custom-metrics-adapter"}, NotBefore: now.Add(-time.Minute), NotAfter: now.Add(24 * time.Hour), KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return tls.Certificate{}, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	return tls.X509KeyPair(certPEM, keyPEM)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("write JSON: %v", err)
	}
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
