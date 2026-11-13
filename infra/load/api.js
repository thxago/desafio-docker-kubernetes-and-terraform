import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: Number(__ENV.VUS || 40),
  duration: __ENV.DURATION || '180s',
  thresholds: {
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
  },
};

export default function () {
  const response = http.get(`${__ENV.BASE_URL}/api/messages`, { timeout: '5s' });
  check(response, {
    'messages responds with HTTP 200': (res) => res.status === 200,
    'messages is a JSON array': (res) => {
      try {
        return Array.isArray(res.json());
      } catch (_) {
        return false;
      }
    },
  });
}