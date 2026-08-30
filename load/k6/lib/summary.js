import { BASE_URL, REQUEST_TIMEOUT } from './config.js';

export function createSummaryHandler(experiment) {
  // k6 handleSummary를 scenario별로 재사용해 raw metric, 재현 metadata, 사람이 읽는 Markdown을 함께 남긴다.
  return (data) => {
    const resultDirectory = __ENV.RESULT_DIR;
    if (!resultDirectory) {
      throw new Error('RESULT_DIR is required; use scripts/run-local-scenario.sh');
    }
    const logicalCount = metricValue(data, 'logical_requests', 'count');
    const physicalCount = metricValue(data, 'physical_attempts', 'count');
    const retryCount = metricValue(data, 'retry_attempts', 'count') ?? 0;
    // Retry amplification은 별도 gauge가 아니라 실행 종료 후 누적 counter로 계산한다.
    const amplification = logicalCount > 0 ? physicalCount / logicalCount : null;
    const logicalFailureRate = metricValue(data, 'logical_failures', 'rate');
    const logicalP95 = metricValue(data, 'logical_request_duration', 'p(95)');
    const httpP95 = metricValue(data, 'http_req_duration', 'p(95)');
    const downstreamStatusCounts = {
      200: metricValue(data, 'downstream_responses_200', 'count') ?? 0,
      503: metricValue(data, 'downstream_responses_503', 'count') ?? 0,
      504: metricValue(data, 'downstream_responses_504', 'count') ?? 0,
      other: metricValue(data, 'downstream_responses_other', 'count') ?? 0,
    };

    // 비교에 필요한 조건만 저장하고 admin token이나 전체 environment는 기록하지 않는다.
    const phase = experiment.phase || 'L00';
    const metadata = {
      project: 'GitHub Capacity Cascade Lab',
      learning_unit: phase,
      phase,
      scenario: experiment.scenario,
      started_at_utc: __ENV.STARTED_AT_UTC || 'unknown',
      git_commit: __ENV.GIT_COMMIT || 'unknown',
      git_dirty: __ENV.GIT_DIRTY === 'true',
      go_version: __ENV.GO_VERSION || 'unknown',
      k6_version: __ENV.K6_VERSION || 'unknown',
      os: __ENV.LAB_OS || 'unknown',
      architecture: __ENV.LAB_ARCH || 'unknown',
      tool_versions: {
        go: __ENV.GO_VERSION || 'unknown',
        k6: __ENV.K6_VERSION || 'unknown',
        docker: __ENV.DOCKER_VERSION || 'not-used',
        docker_compose: __ENV.DOCKER_COMPOSE_VERSION || 'not-used',
        haproxy_server: __ENV.HAPROXY_VERSION || 'not-used',
        toxiproxy_server: __ENV.TOXIPROXY_VERSION || 'not-used',
        envoy_server: __ENV.ENVOY_VERSION || 'not-used',
      },
      image_tags: experiment.imageTags || null,
      base_url: safeOrigin(BASE_URL),
      request_path: experiment.requestPath || 'k6 -> auth-sim',
      logical_rate: experiment.logicalRate,
      duration: experiment.duration,
      request_timeout: experiment.requestTimeout || REQUEST_TIMEOUT,
      fault: experiment.fault,
      application_fault: experiment.applicationFault || experiment.fault,
      proxy_capacity: experiment.proxyCapacity || null,
      network_toxic: experiment.networkToxic || null,
      envoy_proxy: experiment.envoyProxy || null,
      retry_policy: experiment.retryPolicy,
      max_attempts: experiment.maxAttempts,
    };

    // Local runner가 먼저 만든 고유 result directory에만 새 파일을 쓴다.
    return {
      [`${resultDirectory}/metadata.json`]: `${JSON.stringify(metadata, null, 2)}\n`,
      [`${resultDirectory}/k6-summary.json`]: `${JSON.stringify(data, null, 2)}\n`,
      [`${resultDirectory}/summary.md`]: renderMarkdown({
        phase,
        experiment,
        logicalCount,
        physicalCount,
        retryCount,
        amplification,
        logicalFailureRate,
        logicalP95,
        httpP95,
        downstreamStatusCounts,
      }),
      stdout: renderConsole(experiment.scenario, logicalCount, physicalCount, amplification),
    };
  };
}

function renderMarkdown(values) {
  return `# ${values.experiment.scenario} summary

> 이 문서의 수치는 단일 머신에서 생성된 local exploratory result이며 portfolio final evidence가 아니다.

| Metric | Value |
| --- | ---: |
| Scenario | ${values.experiment.scenario} |
| Learning Unit | ${values.phase} |
| Logical Requests | ${formatCount(values.logicalCount)} |
| Physical Attempts | ${formatCount(values.physicalCount)} |
| Retry Attempts | ${formatCount(values.retryCount)} |
| Retry Amplification | ${formatRatio(values.amplification)} |
| Logical Failure Rate | ${formatPercent(values.logicalFailureRate)} |
| Logical Duration P95 | ${formatMilliseconds(values.logicalP95)} |
| HTTP Request Duration P95 | ${formatMilliseconds(values.httpP95)} |
${renderDownstreamStatusRows(values)}

## 실행 조건

- Request path: ${values.experiment.requestPath || 'k6 -> auth-sim'}
- Logical rate: ${values.experiment.logicalRate === null ? 'not applicable' : `${values.experiment.logicalRate} ops/s`}
- Duration: ${values.experiment.duration}
- Request timeout: ${values.experiment.requestTimeout || REQUEST_TIMEOUT}
- Fault: latency_ms=${values.experiment.fault.latency_ms}, error_rate=${values.experiment.fault.error_rate}, max_in_flight=${values.experiment.fault.max_in_flight}, seed=${values.experiment.fault.seed}
- Proxy capacity: ${formatObject(values.experiment.proxyCapacity)}
- Network toxic: ${formatObject(values.experiment.networkToxic)}
- Envoy proxy: ${formatObject(values.experiment.envoyProxy)}
- Retry policy: ${values.experiment.retryPolicy}
- Max attempts: ${values.experiment.maxAttempts}
`;
}

function renderDownstreamStatusRows(values) {
  if (values.phase !== 'L02') {
    return '';
  }
  const counts = values.downstreamStatusCounts;
  return `| Downstream status 200 | ${formatCount(counts[200])} |
| Downstream status 503 | ${formatCount(counts[503])} |
| Downstream status 504 | ${formatCount(counts[504])} |
| Downstream status other/transport | ${formatCount(counts.other)} |`;
}

function formatObject(value) {
  return value === null || value === undefined ? 'not applicable' : JSON.stringify(value);
}

function renderConsole(scenario, logicalCount, physicalCount, amplification) {
  return `${scenario}: logical=${formatCount(logicalCount)} physical=${formatCount(physicalCount)} amplification=${formatRatio(amplification)}\n`;
}

function metricValue(data, metricName, valueName) {
  const metric = data.metrics[metricName];
  if (!metric || !metric.values || metric.values[valueName] === undefined) {
    return null;
  }
  return metric.values[valueName];
}

function formatCount(value) {
  return value === null ? 'n/a' : String(Math.round(value));
}

function formatRatio(value) {
  return value === null ? 'n/a' : `${value.toFixed(3)}x`;
}

function formatPercent(value) {
  return value === null ? 'n/a' : `${(value * 100).toFixed(2)}%`;
}

function formatMilliseconds(value) {
  return value === null ? 'n/a' : `${value.toFixed(2)} ms`;
}

function safeOrigin(value) {
  // URL에 credential이 포함되어도 metadata에는 scheme과 host/port만 남긴다.
  const match = value.match(/^(https?:\/\/)(?:[^/@]+@)?([^/?#]+)/i);
  return match ? `${match[1]}${match[2]}` : 'redacted-invalid-url';
}
