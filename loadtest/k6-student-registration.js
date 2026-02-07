// k6-student-registration.js
// Realistic student registration load test simulating university course registration
//
// Usage:
//   k6 run loadtest/k6-student-registration.js
//   k6 run --vus 500 --duration 60s loadtest/k6-student-registration.js
//   k6 run loadtest/k6-student-registration.js --env TARGET_URL=http://139.162.9.158:8081
//
// Install k6:
//   brew install k6 (macOS)
//   apt install k6 (Ubuntu/Debian)
//   choco install k6 (Windows)

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// Custom metrics
const registrationSuccess = new Rate('registration_success');
const registrationLatency = new Trend('registration_latency');
const pageLoadLatency = new Trend('page_load_latency');
const errorCounter = new Counter('errors');

// Configuration - simulates 2000 students registering for courses
export const options = {
    scenarios: {
        // Scenario 1: Gradual ramp-up (like registration opening time)
        registration_rush: {
            executor: 'ramping-vus',
            startVUs: 0,
            stages: [
                { duration: '30s', target: 500 },    // Ramp to 500 users
                { duration: '1m', target: 2000 },    // Ramp to 2000 users
                { duration: '2m', target: 2000 },    // Stay at 2000 users (peak load)
                { duration: '30s', target: 500 },    // Ramp down to 500
                { duration: '30s', target: 0 },      // Ramp down to 0
            ],
            gracefulRampDown: '30s',
        },
    },
    thresholds: {
        http_req_duration: ['p(95)<500'],           // 95% of requests under 500ms
        http_req_failed: ['rate<0.01'],             // Less than 1% errors
        registration_success: ['rate>0.95'],        // 95% registration success
    },
};

// Target URL - can be overridden with --env TARGET_URL=...
const BASE_URL = __ENV.TARGET_URL || 'http://localhost:8081';

// Simulated student data generator
function generateStudent() {
    const studentId = `STU${Math.floor(Math.random() * 100000)}`;
    return {
        student_id: studentId,
        email: `${studentId.toLowerCase()}@university.edu`,
        subjects: [
            `SUBJ${Math.floor(Math.random() * 500)}`,
            `SUBJ${Math.floor(Math.random() * 500)}`,
            `SUBJ${Math.floor(Math.random() * 500)}`,
        ],
    };
}

// Simulate a complete student registration flow
export default function () {
    const student = generateStudent();
    const headers = {
        'Content-Type': 'application/json',
        'X-Student-ID': student.student_id,
    };

    // Step 1: Login page (GET /)
    let loginStart = Date.now();
    let loginRes = http.get(`${BASE_URL}/`, { headers });
    pageLoadLatency.add(Date.now() - loginStart);

    check(loginRes, {
        'login page': (r) => r.status === 200,
    }) || errorCounter.add(1);

    sleep(0.5 + Math.random()); // User thinks for 0.5-1.5 seconds

    // Step 2: View available subjects (GET /)
    let subjectsStart = Date.now();
    let subjectsRes = http.get(`${BASE_URL}/`, { headers });
    pageLoadLatency.add(Date.now() - subjectsStart);

    check(subjectsRes, {
        'view subjects': (r) => r.status === 200,
    }) || errorCounter.add(1);

    sleep(1 + Math.random() * 2); // User browses for 1-3 seconds

    // Step 3: Submit registration (POST /)
    let regStart = Date.now();
    let regRes = http.post(
        `${BASE_URL}/`,
        JSON.stringify({
            student_id: student.student_id,
            email: student.email,
            subjects: student.subjects,
            action: 'register',
        }),
        { headers }
    );
    registrationLatency.add(Date.now() - regStart);

    let regSuccess = check(regRes, {
        'registration': (r) => r.status === 200 || r.status === 201,
    });

    registrationSuccess.add(regSuccess);
    if (!regSuccess) errorCounter.add(1);

    sleep(0.5 + Math.random()); // Brief pause

    // Step 4: View timetable/confirmation (GET /)
    let timetableStart = Date.now();
    let timetableRes = http.get(`${BASE_URL}/`, { headers });
    pageLoadLatency.add(Date.now() - timetableStart);

    check(timetableRes, {
        'timetable': (r) => r.status === 200,
    }) || errorCounter.add(1);

    sleep(1 + Math.random()); // User reviews timetable
}

// Lifecycle hooks
export function setup() {
    console.log(`🎓 Student Registration Load Test`);
    console.log(`📍 Target: ${BASE_URL}`);
    console.log(`👥 Max VUs: 2000`);
    console.log(`⏱️  Duration: ~5 minutes`);

    // Verify server is accessible
    const res = http.get(`${BASE_URL}/health`);
    if (res.status !== 200) {
        console.error(`❌ Server health check failed: ${res.status}`);
        throw new Error('Server not accessible');
    }
    console.log(`✅ Server health check passed`);

    return { startTime: Date.now() };
}

export function teardown(data) {
    const duration = (Date.now() - data.startTime) / 1000;
    console.log(`\n📊 Test completed in ${duration.toFixed(1)} seconds`);
}
