// k6-compare-servers.js
// Compare Worker Pool (8080) vs Chi Web (8081) servers
//
// Usage:
//   k6 run loadtest/k6-compare-servers.js
//   k6 run loadtest/k6-compare-servers.js --env HOST=139.162.9.158

import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';

// Custom metrics per server
const workerPoolLatency = new Trend('worker_pool_latency');
const chiWebLatency = new Trend('chi_web_latency');
const workerPoolErrors = new Counter('worker_pool_errors');
const chiWebErrors = new Counter('chi_web_errors');

const HOST = __ENV.HOST || 'localhost';
const WORKER_POOL_URL = `http://${HOST}:8080`;
const CHI_WEB_URL = `http://${HOST}:8081`;

export const options = {
    scenarios: {
        compare_servers: {
            executor: 'ramping-vus',
            startVUs: 0,
            stages: [
                { duration: '30s', target: 500 },
                { duration: '1m', target: 1000 },
                { duration: '1m', target: 1000 },
                { duration: '30s', target: 0 },
            ],
        },
    },
    thresholds: {
        worker_pool_latency: ['p(95)<500'],
        chi_web_latency: ['p(95)<200'],
        worker_pool_errors: ['count<100'],
        chi_web_errors: ['count<100'],
    },
};

export default function () {
    // Test Worker Pool Server (100ms simulated work)
    group('Worker Pool (8080)', function () {
        const start = Date.now();
        const res = http.get(`${WORKER_POOL_URL}/`);
        workerPoolLatency.add(Date.now() - start);

        if (!check(res, { 'worker pool ok': (r) => r.status === 200 })) {
            workerPoolErrors.add(1);
        }
    });

    sleep(0.1);

    // Test Chi Web Server (10ms simulated work)
    group('Chi Web (8081)', function () {
        const start = Date.now();
        const res = http.get(`${CHI_WEB_URL}/`);
        chiWebLatency.add(Date.now() - start);

        if (!check(res, { 'chi web ok': (r) => r.status === 200 })) {
            chiWebErrors.add(1);
        }
    });

    sleep(0.2 + Math.random() * 0.3);
}

export function setup() {
    console.log(`📊 Server Comparison Test`);
    console.log(`🔵 Worker Pool: ${WORKER_POOL_URL} (100ms work)`);
    console.log(`🟢 Chi Web:     ${CHI_WEB_URL} (10ms work)`);
    console.log(`👥 Max VUs: 1000`);

    // Check both servers
    const wp = http.get(`${WORKER_POOL_URL}/health`);
    const chi = http.get(`${CHI_WEB_URL}/health`);

    if (wp.status !== 200) {
        console.error(`❌ Worker Pool server not accessible`);
    } else {
        console.log(`✅ Worker Pool server ready`);
    }

    if (chi.status !== 200) {
        console.error(`❌ Chi Web server not accessible`);
    } else {
        console.log(`✅ Chi Web server ready`);
    }
}

export function handleSummary(data) {
    const wpP95 = data.metrics.worker_pool_latency?.values?.['p(95)'] || 'N/A';
    const chiP95 = data.metrics.chi_web_latency?.values?.['p(95)'] || 'N/A';

    console.log(`\n📈 Results Summary:`);
    console.log(`   Worker Pool p95: ${typeof wpP95 === 'number' ? wpP95.toFixed(2) : wpP95}ms`);
    console.log(`   Chi Web p95:     ${typeof chiP95 === 'number' ? chiP95.toFixed(2) : chiP95}ms`);

    return {};
}
