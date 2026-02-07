// k6-quick.js
// Quick 60-second load test for development
//
// Usage:
//   k6 run loadtest/k6-quick.js
//   k6 run loadtest/k6-quick.js --env TARGET_URL=http://your-server:8081
//   k6 run loadtest/k6-quick.js --env VUS=100

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.TARGET_URL || 'http://localhost:8081';
const VUS = parseInt(__ENV.VUS) || 200;

export const options = {
    vus: VUS,
    duration: '60s',
    thresholds: {
        http_req_duration: ['p(95)<300'],  // 95% under 300ms
        http_req_failed: ['rate<0.01'],    // Less than 1% errors
    },
};

export default function () {
    // Health check
    let healthRes = http.get(`${BASE_URL}/health`);
    check(healthRes, { 'health ok': (r) => r.status === 200 });

    // Main endpoint
    let mainRes = http.get(`${BASE_URL}/`);
    check(mainRes, {
        'status 200': (r) => r.status === 200,
        'fast response': (r) => r.timings.duration < 200,
    });

    sleep(0.5 + Math.random() * 0.5);
}

export function setup() {
    console.log(`⚡ Quick Load Test (60s)`);
    console.log(`📍 Target: ${BASE_URL}`);
    console.log(`👥 VUs: ${VUS}`);
}
