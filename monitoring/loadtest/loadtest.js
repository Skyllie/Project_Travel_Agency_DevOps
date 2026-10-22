// Load test of TravelAgency with k6, run by loadtest.py (one run per number of virtual users).
// Every iteration is a new visitor: opens the login page and, with LOGIN_USER set, signs in
// (the start page after sign-in reads the database). Then waits 1 s, like a person reading.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://travelagency-tf-lb';
const USER = __ENV.LOGIN_USER || '';
const PASSWORD = __ENV.LOGIN_PASSWORD || '';

export const options = {
  scenarios: {
    visitors: {
      executor: 'constant-vus',
      vus: Number(__ENV.VUS || 10),
      duration: __ENV.DURATION || '2m',
    },
  },
  // The service level the capacity plan uses: 95 % of requests under 1 s, under 1 % errors
  thresholds: {
    http_req_duration: ['p(95)<1000'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  // A new visitor: no session cookie, so the load balancer may pick any server
  http.cookieJar().clear(BASE);

  const form = http.get(`${BASE}/form-login`, { tags: { page: 'login form' } });
  check(form, { 'login form: 200': (r) => r.status === 200 });

  if (USER) {
    const start = http.post(`${BASE}/form-login`, { username: USER, password: PASSWORD },
      { tags: { page: 'sign in' } });
    check(start, { 'signed in': (r) => r.status === 200 && !r.url.includes('form-login') });
  }
  sleep(1);
}

// Numbers for loadtest.py: the whole summary as JSON
export function handleSummary(data) {
  return { [__ENV.SUMMARY_FILE || '/results/summary.json']: JSON.stringify(data, null, 2) };
}
