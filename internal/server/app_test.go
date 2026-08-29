package server

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/imcherry5778-labs/github-capacity-cascade-lab/internal/fault"
)

func TestHealthAndReadyIgnoreFaults(t *testing.T) {
	app := NewApplication("test-token")
	if err := app.Faults().Update(fault.Config{LatencyMS: 1_000, ErrorRate: 1, MaxInFlight: 1, Seed: 1}); err != nil {
		t.Fatal(err)
	}

	for _, path := range []string{"/healthz", "/readyz", "/auth/status"} {
		t.Run(path, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, path, nil)
			response := httptest.NewRecorder()
			started := time.Now()
			app.PublicHandler().ServeHTTP(response, request)
			if response.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200", response.Code)
			}
			if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
				t.Fatalf("fault-independent endpoint took %v", elapsed)
			}
		})
	}
}

func TestTokenResponses(t *testing.T) {
	tests := []struct {
		name       string
		config     fault.Config
		wantStatus int
		wantCode   string
	}{
		{name: "normal", config: fault.DefaultConfig(), wantStatus: http.StatusOK},
		{name: "injected error", config: fault.Config{ErrorRate: 1, Seed: 1}, wantStatus: http.StatusServiceUnavailable, wantCode: "injected_fault"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			app := NewApplication("test-token")
			if err := app.Faults().Update(test.config); err != nil {
				t.Fatal(err)
			}
			request := httptest.NewRequest(http.MethodPost, "/token", nil)
			request.Header.Set("X-Lab-Logical-Request-ID", "logical-1")
			request.Header.Set("X-Lab-Attempt", "2")
			response := httptest.NewRecorder()
			app.PublicHandler().ServeHTTP(response, request)
			if response.Code != test.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", response.Code, test.wantStatus, response.Body.String())
			}
			if got := response.Header().Get("X-Lab-Logical-Request-ID"); got != "logical-1" {
				t.Fatalf("request ID header = %q", got)
			}
			if test.wantCode == "" {
				var body tokenResponse
				if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
					t.Fatal(err)
				}
				if body.Token != "lab-token-placeholder" || body.RequestID != "logical-1" || body.Attempt != 2 {
					t.Fatalf("unexpected body: %+v", body)
				}
				return
			}
			var body errorResponse
			if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if body.Error.Code != test.wantCode {
				t.Fatalf("error code = %q, want %q", body.Error.Code, test.wantCode)
			}
		})
	}
}

func TestTokenLatencyAndCancellation(t *testing.T) {
	t.Run("latency applies", func(t *testing.T) {
		app := NewApplication("test-token")
		if err := app.Faults().Update(fault.Config{LatencyMS: 30, Seed: 1}); err != nil {
			t.Fatal(err)
		}
		request := httptest.NewRequest(http.MethodPost, "/token", nil)
		response := httptest.NewRecorder()
		started := time.Now()
		app.PublicHandler().ServeHTTP(response, request)
		if elapsed := time.Since(started); elapsed < 25*time.Millisecond {
			t.Fatalf("request returned before configured latency: %v", elapsed)
		}
	})

	t.Run("cancellation ends latency", func(t *testing.T) {
		app := NewApplication("test-token")
		if err := app.Faults().Update(fault.Config{LatencyMS: 1_000, Seed: 1}); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		request := httptest.NewRequest(http.MethodPost, "/token", nil).WithContext(ctx)
		response := httptest.NewRecorder()
		started := time.Now()
		app.PublicHandler().ServeHTTP(response, request)
		if response.Code != http.StatusServiceUnavailable {
			t.Fatalf("status = %d, want 503", response.Code)
		}
		if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
			t.Fatalf("cancelled request took %v", elapsed)
		}
		if got := app.InFlight(); got != 0 {
			t.Fatalf("in-flight after cancellation = %d", got)
		}
	})
}

func TestMaxInFlightRejectsFastAndDoesNotLeak(t *testing.T) {
	app := NewApplication("test-token")
	if err := app.Faults().Update(fault.Config{LatencyMS: 1_000, MaxInFlight: 1, Seed: 1}); err != nil {
		t.Fatal(err)
	}
	handler := app.PublicHandler()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	firstDone := make(chan struct{})
	go func() {
		defer close(firstDone)
		request := httptest.NewRequest(http.MethodPost, "/token", nil).WithContext(ctx)
		handler.ServeHTTP(httptest.NewRecorder(), request)
	}()

	deadline := time.Now().Add(500 * time.Millisecond)
	for app.InFlight() != 1 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if app.InFlight() != 1 {
		t.Fatal("first request was not admitted")
	}

	response := httptest.NewRecorder()
	started := time.Now()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/token", nil))
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("second status = %d, want 503", response.Code)
	}
	if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
		t.Fatalf("rejection waited for capacity: %v", elapsed)
	}
	cancel()
	select {
	case <-firstDone:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("first request did not exit after cancellation")
	}
	if got := app.InFlight(); got != 0 {
		t.Fatalf("in-flight after completion = %d", got)
	}
}

func TestAdminFaultMutationAuthAndValidation(t *testing.T) {
	validBody := `{"latency_ms":10,"error_rate":0.25,"max_in_flight":3,"seed":7}`
	tests := []struct {
		name       string
		appToken   string
		auth       string
		body       string
		wantStatus int
	}{
		{name: "unconfigured", appToken: "", body: validBody, wantStatus: http.StatusServiceUnavailable},
		{name: "missing token", appToken: "test-token", body: validBody, wantStatus: http.StatusUnauthorized},
		{name: "wrong token", appToken: "test-token", auth: "Bearer wrong", body: validBody, wantStatus: http.StatusUnauthorized},
		{name: "invalid config", appToken: "test-token", auth: "Bearer test-token", body: `{"latency_ms":-1}`, wantStatus: http.StatusBadRequest},
		{name: "unknown field", appToken: "test-token", auth: "Bearer test-token", body: `{"latency_ms":0,"unexpected":1}`, wantStatus: http.StatusBadRequest},
		{name: "valid", appToken: "test-token", auth: "Bearer test-token", body: validBody, wantStatus: http.StatusOK},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			app := NewApplication(test.appToken)
			request := httptest.NewRequest(http.MethodPut, "/admin/fault", strings.NewReader(test.body))
			request.Header.Set("Authorization", test.auth)
			response := httptest.NewRecorder()
			app.AdminHandler().ServeHTTP(response, request)
			if response.Code != test.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", response.Code, test.wantStatus, response.Body.String())
			}
			if test.wantStatus == http.StatusOK {
				got := app.Faults().Load()
				if got.Seed != 7 || got.MaxInFlight != 3 {
					t.Fatalf("stored config = %+v", got)
				}
			}
		})
	}
}

func TestMetricsExposeRequiredNamesWithoutRequestIDLabel(t *testing.T) {
	app := NewApplication("test-token")
	request := httptest.NewRequest(http.MethodPost, "/token", nil)
	request.Header.Set("X-Lab-Logical-Request-ID", "secret-like-unique-request-id")
	app.PublicHandler().ServeHTTP(httptest.NewRecorder(), request)

	response := httptest.NewRecorder()
	app.PublicHandler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("metrics status = %d", response.Code)
	}
	body := response.Body.String()
	for _, name := range []string{
		"capacity_cascade_http_requests_total",
		"capacity_cascade_http_request_duration_seconds",
		"capacity_cascade_http_in_flight",
		"capacity_cascade_fault_injections_total",
		"capacity_cascade_admission_rejections_total",
	} {
		if !strings.Contains(body, name) {
			t.Errorf("metrics output missing %s", name)
		}
	}
	if strings.Contains(body, "secret-like-unique-request-id") || strings.Contains(body, "request_id=") {
		t.Fatal("metrics output contains request ID data")
	}
}

func TestGetFault(t *testing.T) {
	app := NewApplication("test-token")
	response := httptest.NewRecorder()
	app.AdminHandler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/admin/fault", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d", response.Code)
	}
	data, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data, []byte(`"seed":17082026`)) {
		t.Fatalf("unexpected body: %s", data)
	}
}
