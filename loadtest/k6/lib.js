import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

export const BASE = __ENV.BASE_URL || 'http://localhost:8080';

// Chỉ đếm lỗi KỸ THUẬT (5xx, timeout, lỗi mạng).
// 409 Conflict là hành vi ĐÚNG của optimistic locking, không tính là lỗi.
export const techErrors  = new Rate('technical_error_rate');
export const orderLatency = new Trend('order_create_ms', true);
export const accepted    = new Counter('orders_accepted');
export const rejected503 = new Counter('orders_rejected_503');

const CUSTOMERS = Array.from({ length: 150 }, (_, i) =>
  `CUST${String(i + 1).padStart(4, '0')}`);
const SKUS = [];
for (const p of ['VAN','BRG','MTR','PMP','SEN','CBL','FLT','GBX']) {
  for (let i = 1; i <= 10; i++) SKUS.push(`${p}-${String(i).padStart(3,'0')}`);
}

const pick = a => a[Math.floor(Math.random() * a.length)];

export function idempotencyKey() {
  return `k6-${__VU}-${__ITER}-${Date.now()}-${Math.random().toString(16).slice(2, 10)}`;
}

export function createOrder() {
  const payload = JSON.stringify({
    customer_code: pick(CUSTOMERS),
    items: [{ sku: pick(SKUS), quantity: 1 + Math.floor(Math.random() * 10) }],
  });

  const res = http.post(`${BASE}/api/orders`, payload, {
    headers: {
      'Content-Type': 'application/json',
      'Idempotency-Key': idempotencyKey(),
    },
    tags: { name: 'POST /orders' },
  });

  orderLatency.add(res.timings.duration);

  // 201 = đã ghi (sync)   202 = đã tiếp nhận (async)
  const ok = res.status === 201 || res.status === 202;
  if (ok) accepted.add(1);
  if (res.status === 503) rejected503.add(1);

  // 503 là câu trả lời TRUNG THỰC khi DB chết - nhưng vẫn tính là lỗi kỹ thuật
  // để ràng buộc "tỷ lệ lỗi <= 1%" ở mục #4 phản ánh đúng trải nghiệm người dùng.
  techErrors.add(!ok);

  check(res, {
    'đơn được tiếp nhận (201/202)': r => r.status === 201 || r.status === 202,
    'không phải lỗi 5xx': r => r.status < 500,
    'trả về order_id': r => {
      try { return !!r.json('order_id'); } catch (e) { return false; }
    },
  });

  return res;
}

export function browse() {
  const res = http.get(`${BASE}/api/orders?limit=15`, {
    tags: { name: 'GET /orders' },
  });
  techErrors.add(res.status >= 500);
  check(res, { 'danh sách đơn OK': r => r.status === 200 });
  return res;
}
