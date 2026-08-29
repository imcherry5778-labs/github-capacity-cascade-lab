package server

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/imcherry5778-labs/github-capacity-cascade-lab/internal/fault"
	"github.com/imcherry5778-labs/github-capacity-cascade-lab/internal/telemetry"
)

const maxAdminBodyBytes = 16 << 10

type Application struct {
	faults     *fault.Store
	limiter    fault.Limiter
	metrics    *telemetry.Metrics
	adminToken string
	requestSeq atomic.Uint64
}

type tokenResponse struct {
	Token     string `json:"token"`
	ExpiresIn int    `json:"expires_in"`
	RequestID string `json:"request_id"`
	Attempt   int64  `json:"attempt"`
}

type statusResponse struct {
	Status        string `json:"status"`
	Authenticated bool   `json:"authenticated"`
	Mode          string `json:"mode"`
}

type errorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type errorResponse struct {
	Error     errorDetail `json:"error"`
	RequestID string      `json:"request_id,omitempty"`
	Attempt   int64       `json:"attempt,omitempty"`
}

func NewApplication(adminToken string) *Application {
	store, err := fault.NewStore(fault.DefaultConfig())
	if err != nil {
		panic(err)
	}
	return &Application{
		faults:     store,
		metrics:    telemetry.New(),
		adminToken: adminToken,
	}
}

func (a *Application) PublicHandler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("POST /token", a.observe("/token", http.HandlerFunc(a.handleToken)))
	mux.Handle("GET /auth/status", a.observe("/auth/status", http.HandlerFunc(a.handleAuthStatus)))
	mux.Handle("GET /healthz", a.observe("/healthz", http.HandlerFunc(a.handleHealth)))
	mux.Handle("GET /readyz", a.observe("/readyz", http.HandlerFunc(a.handleReady)))
	mux.Handle("GET /metrics", a.metrics.Handler())
	return mux
}

func (a *Application) AdminHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /admin/fault", a.handleGetFault)
	mux.HandleFunc("PUT /admin/fault", a.handlePutFault)
	return mux
}

func (a *Application) Faults() *fault.Store {
	return a.faults
}

func (a *Application) InFlight() int64 {
	return a.limiter.InFlight()
}

func (a *Application) handleToken(w http.ResponseWriter, r *http.Request) {
	requestID := strings.TrimSpace(r.Header.Get("X-Lab-Logical-Request-ID"))
	if requestID == "" {
		requestID = fmt.Sprintf("local-%d", a.requestSeq.Add(1))
	}
	attempt := parseAttempt(r.Header.Get("X-Lab-Attempt"))
	w.Header().Set("X-Lab-Logical-Request-ID", requestID)
	w.Header().Set("X-Lab-Attempt", strconv.FormatInt(attempt, 10))

	config := a.faults.Load()
	if !a.limiter.TryAcquire(config.MaxInFlight) {
		a.metrics.IncAdmissionRejection()
		writeError(w, http.StatusServiceUnavailable, "admission_rejected", "application admission limit reached", requestID, attempt)
		return
	}
	a.metrics.IncInFlight()
	defer func() {
		a.metrics.DecInFlight()
		a.limiter.Release()
	}()

	if config.LatencyMS > 0 {
		a.metrics.IncFault("latency")
		if err := fault.Wait(r.Context(), time.Duration(config.LatencyMS)*time.Millisecond); err != nil {
			writeError(w, http.StatusServiceUnavailable, "request_cancelled", "request context ended during injected latency", requestID, attempt)
			return
		}
	}

	if fault.ShouldError(config.Seed, requestID, attempt, config.ErrorRate) {
		a.metrics.IncFault("error")
		writeError(w, http.StatusServiceUnavailable, "injected_fault", "deterministic lab fault injected", requestID, attempt)
		return
	}

	writeJSON(w, http.StatusOK, tokenResponse{
		Token:     "lab-token-placeholder",
		ExpiresIn: 300,
		RequestID: requestID,
		Attempt:   attempt,
	})
}

func (a *Application) handleAuthStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, statusResponse{
		Status:        "ok",
		Authenticated: false,
		Mode:          "lab-simulation",
	})
}

func (a *Application) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *Application) handleReady(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (a *Application) handleGetFault(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, a.faults.Load())
}

func (a *Application) handlePutFault(w http.ResponseWriter, r *http.Request) {
	if a.adminToken == "" {
		writeError(w, http.StatusServiceUnavailable, "admin_auth_unconfigured", "fault mutation is disabled", "", 0)
		return
	}
	expected := "Bearer " + a.adminToken
	provided := r.Header.Get("Authorization")
	if subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) != 1 {
		w.Header().Set("WWW-Authenticate", "Bearer")
		writeError(w, http.StatusUnauthorized, "unauthorized", "valid bearer token required", "", 0)
		return
	}

	decoder := json.NewDecoder(io.LimitReader(r.Body, maxAdminBodyBytes))
	decoder.DisallowUnknownFields()
	var config fault.Config
	if err := decoder.Decode(&config); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "fault configuration must be valid JSON", "", 0)
		return
	}
	if err := ensureJSONEOF(decoder); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "request body must contain one JSON object", "", 0)
		return
	}
	if err := a.faults.Update(config); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_fault_config", err.Error(), "", 0)
		return
	}
	writeJSON(w, http.StatusOK, config)
}

func (a *Application) observe(route string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(recorder, r)
		statusClass := strconv.Itoa(recorder.status/100) + "xx"
		a.metrics.ObserveHTTP(route, r.Method, statusClass, time.Since(started))
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(status int) {
	if r.wroteHeader {
		return
	}
	r.status = status
	r.wroteHeader = true
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(body []byte) (int, error) {
	if !r.wroteHeader {
		r.WriteHeader(http.StatusOK)
	}
	return r.ResponseWriter.Write(body)
}

func parseAttempt(raw string) int64 {
	attempt, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil || attempt < 1 {
		return 1
	}
	return attempt
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var extra any
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return errors.New("extra JSON value")
	}
	return err
}

func writeError(w http.ResponseWriter, status int, code, message, requestID string, attempt int64) {
	writeJSON(w, status, errorResponse{
		Error:     errorDetail{Code: code, Message: message},
		RequestID: requestID,
		Attempt:   attempt,
	})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
