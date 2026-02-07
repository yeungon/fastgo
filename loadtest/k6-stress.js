// k6-stress.js
// Stress test to find server breaking point
//
// Usage:
//   k6 run loadtest/k6-stress.js
//   k6 run loadtest/k6-stress.js --env TARGET_URL=http://your-server:8081

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('errors');

export const options = {
    scenarios: {
        stress_test: {
            executor: 'ramping-vus',
            startVUs: 0,
            stages: [
                { duration: '1m', target: 1000 },    // Warm up
                { duration: '2m', target: 2000 },    // Normal load
                { duration: '2m', target: 3000 },    // High load
                { duration: '2m', target: 5000 },    // Stress load
                { duration: '2m', target: 7000 },    // Breaking point?
                { duration: '2m', target: 10000 },   // Maximum stress
                { duration: '1m', target: 0 },       // Recovery
            ],
            gracefulRampDown: '30s',
        },
    },
    thresholds: {
        http_req_duration: ['p(99)<2000'],  // 99% under 2s
        errors: ['rate<0.1'],               // Less than 10% errors
    },
};

const BASE_URL = __ENV.TARGET_URL || 'http://localhost:8081';

export default function () {
    const res = http.get(`${BASE_URL}/`);

    const success = check(res, {
        'status is 200': (r) => r.status === 200,
        'response time < 1000ms': (r) => r.timings.duration < 1000,
    });

    errorRate.add(!success);

    sleep(0.1 + Math.random() * 0.2);  // 100-300ms between requests
}

export function setup() {
    console.log(`🔥 Stress Test - Finding Breaking Point`);
    console.log(`📍 Target: ${BASE_URL}`);
    console.log(`👥 Max VUs: 10,000`);
    console.log(`⏱️  Duration: ~12 minutes`);

    const res = http.get(`${BASE_URL}/health`);
    if (res.status !== 200) {
        throw new Error('Server not accessible');
    }
    console.log(`✅ Server ready`);
}
