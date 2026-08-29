import { BASE_URL } from './config.js';

export function createSummaryHandler(experiment) {
  return (data) => {
    const resultDirectory = __ENV.RESULT_DIR;
    if (!resultDirectory) {
      throw new Error('RESULT_DIR is required; use scripts/run-local-scenario.sh');
    }
    const logicalCount = metricValue(data, 'logical_requests', 'count');
    const physicalCount = metricValue(data, 'physical_attempts', 'count');
    const retryCount = metricValue(data, 'retry_attempts', 'count') ?? 0;
    const amplification = logicalCount > 0 ? physicalCount / logicalCount : null;
    const logicalFailureRate = metricValue(data, 'logical_failures', 'rate');
    const logicalP95 = metricValue(data, 'logical_request_duration', 'p(95)');
    const httpP95 = metricValue(data, 'http_req_duration', 'p(95)');

    const metadata = {
      project: 'GitHub Capacity Cascade Lab',
      phase: 'L00',
      scenario: experiment.scenario,
      started_at_utc: __ENV.STARTED_AT_UTC || 'unknown',
      git_commit: __ENV.GIT_COMMIT || 'unknown',
      git_dirty: __ENV.GIT_DIRTY === 'true',
      go_version: __ENV.GO_VERSION || 'unknown',
      k6_version: __ENV.K6_VERSION || 'unknown',
      os: __ENV.LAB_OS || 'unknown',
      architecture: __ENV.LAB_ARCH || 'unknown',
      base_url: safeOrigin(BASE_URL),
      logical_rate: experiment.logicalRate,
      duration: experiment.duration,
      fault: experiment.fault,
      retry_policy: experiment.retryPolicy,
      max_attempts: experiment.maxAttempts,
    };

    return {
      [`${resultDirectory}/metadata.json`]: `${JSON.stringify(metadata, null, 2)}\n`,
      [`${resultDirectory}/k6-summary.json`]: `${JSON.stringify(data, null, 2)}\n`,
      [`${resultDirectory}/summary.md`]: renderMarkdown({
        experiment,
        logicalCount,
        physicalCount,
        retryCount,
        amplification,
        logicalFailureRate,
        logicalP95,
        httpP95,
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
| Logical Requests | ${formatCount(values.logicalCount)} |
| Physical Attempts | ${formatCount(values.physicalCount)} |
| Retry Attempts | ${formatCount(values.retryCount)} |
| Retry Amplification | ${formatRatio(values.amplification)} |
| Logical Failure Rate | ${formatPercent(values.logicalFailureRate)} |
| Logical Duration P95 | ${formatMilliseconds(values.logicalP95)} |
| HTTP Request Duration P95 | ${formatMilliseconds(values.httpP95)} |

## 실행 조건

- Logical rate: ${values.experiment.logicalRate === null ? 'not applicable' : `${values.experiment.logicalRate} ops/s`}
- Duration: ${values.experiment.duration}
- Fault: latency_ms=${values.experiment.fault.latency_ms}, error_rate=${values.experiment.fault.error_rate}, max_in_flight=${values.experiment.fault.max_in_flight}, seed=${values.experiment.fault.seed}
- Retry policy: ${values.experiment.retryPolicy}
- Max attempts: ${values.experiment.maxAttempts}
`;
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
  const match = value.match(/^(https?:\/\/)(?:[^/@]+@)?([^/?#]+)/i);
  return match ? `${match[1]}${match[2]}` : 'redacted-invalid-url';
}
