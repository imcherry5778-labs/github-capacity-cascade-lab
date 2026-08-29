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
	// Public workload와 admin control plane은 handler를 분리하지만 fault/metric 상태는 하나의 application에서 공유한다.
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
	// Fault는 /token에만 적용한다. health/readiness/status는 장애 주입 중에도 독립적으로 응답한다.
	mux := http.NewServeMux()
	mux.Handle("POST /token", a.observe("/token", http.HandlerFunc(a.handleToken)))
	mux.Handle("GET /auth/status", a.observe("/auth/status", http.HandlerFunc(a.handleAuthStatus)))
	mux.Handle("GET /healthz", a.observe("/healthz", http.HandlerFunc(a.handleHealth)))
	mux.Handle("GET /readyz", a.observe("/readyz", http.HandlerFunc(a.handleReady)))
	mux.Handle("GET /metrics", a.metrics.Handler())
	return mux
}

func (a *Application) AdminHandler() http.Handler {
	// Fault 조회와 변경은 public mux에 노출하지 않는 별도 control plane이다.
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
	// 같은 logical request의 retry는 request ID를 공유하고 attempt만 증가시켜 증폭을 계산할 수 있게 한다.
	requestID := strings.TrimSpace(r.Header.Get("X-Lab-Logical-Request-ID"))
	if requestID == "" {
		requestID = fmt.Sprintf("local-%d", a.requestSeq.Add(1))
	}
	attempt := parseAttempt(r.Header.Get("X-Lab-Attempt"))
	w.Header().Set("X-Lab-Logical-Request-ID", requestID)
	w.Header().Set("X-Lab-Attempt", strconv.FormatInt(attempt, 10))

	// 요청 처리 중 admin 설정이 바뀌어도 이 요청은 시작 시점의 하나의 snapshot만 사용한다.
	config := a.faults.Load()
	// 제한 초과 요청은 내부 queue를 만들지 않고 503으로 빠르게 거절한다.
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
		// Context-aware wait를 사용해 client timeout이나 취소 후에 불필요한 작업을 계속하지 않는다.
		a.metrics.IncFault("latency")
		if err := fault.Wait(r.Context(), time.Duration(config.LatencyMS)*time.Millisecond); err != nil {
			writeError(w, http.StatusServiceUnavailable, "request_cancelled", "request context ended during injected latency", requestID, attempt)
			return
		}
	}

	if fault.ShouldError(config.Seed, requestID, attempt, config.ErrorRate) {
		// 재현 가능한 503을 반환해 k6 retry 정책의 차이를 비교한다.
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
	// Credential이 없으면 mutation을 비활성화해 실수로 fault를 바꾸지 못하게 한다.
	if a.adminToken == "" {
		writeError(w, http.StatusServiceUnavailable, "admin_auth_unconfigured", "fault mutation is disabled", "", 0)
		return
	}
	// Token 비교 시 timing 차이로 credential 정보가 노출되지 않도록 constant-time 비교를 사용한다.
	expected := "Bearer " + a.adminToken
	provided := r.Header.Get("Authorization")
	if subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) != 1 {
		w.Header().Set("WWW-Authenticate", "Bearer")
		writeError(w, http.StatusUnauthorized, "unauthorized", "valid bearer token required", "", 0)
		return
	}

	// Body 크기와 필드를 제한해 알 수 없는 설정이 무시되는 일을 막는다.
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
	// Route, method, status class만 label로 사용하고 request ID나 사용자 입력은 metric label에 넣지 않는다.
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
