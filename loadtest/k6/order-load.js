// ---------------------------------------------------------------------------
// Test B1 — Ràng buộc #4: chịu tải gấp 5 lần trong 30 phút.
//   p95 <= 2 giây, tỷ lệ lỗi kỹ thuật <= 1%.
//
// Kịch bản 3 giai đoạn:
//   warmup   — 50 req/s (tải bình thường đã thống nhất), làm nóng ASG + pool
//   peak     — 250 req/s (5x) trong 30 phút  <- đây là phần chấm điểm
//   cooldown — về 50 req/s để quan sát ASG scale-in
//
// Chạy:
//   docker run --rm --network host -v "$PWD/loadtest/k6:/scripts" \
//     -e BASE_URL=http://localhost:8080 grafana/k6 run /scripts/order-load.js
//
//   # bản rút gọn để thử nhanh trước khi chạy 30 phút thật
//   ... -e PROFILE=smoke ...
//
// Chạy load generator NGOÀI VPC (hoặc ít nhất subnet riêng) để không tự làm
// nhiễu kết quả đo của chính hệ thống đang test.
// ---------------------------------------------------------------------------
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { randomIntBetween, uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

const BASE_URL   = __ENV.BASE_URL   || 'http://localhost:8080';
const PROFILE    = __ENV.PROFILE    || 'full';
const NORMAL_RPS = Number(__ENV.NORMAL_RPS || 50);
const PEAK_RPS   = Number(__ENV.PEAK_RPS   || 250);
const PEAK_MIN   = Number(__ENV.PEAK_MIN   || 30);

// Tỷ lệ hành vi, phỏng theo web bán hàng B2B: đọc nhiều hơn ghi.
const MIX = { create: 0.35, read: 0.45, list: 0.20 };

const orderCreated  = new Counter('orders_created');
const orderRejected = new Counter('orders_rejected');
const businessError = new Rate('business_error_rate');
const createLatency = new Trend('create_order_latency', true);

const CUSTOMERS = Array.from({ length: 60 }, (_, i) => `CUST-${String(i + 1).padStart(4, '0')}`);
const SKUS = ['BRG', 'MTR', 'VLV', 'PMP', 'GBX', 'BLT', 'SNS', 'PLC']
  .flatMap(p => Array.from({ length: 6 }, (_, i) => `${p}-${String(i + 1).padStart(3, '0')}`));

const stages = PROFILE === 'smoke'
  ? [ { target: NORMAL_RPS, duration: '30s' },
      { target: PEAK_RPS,   duration: '30s' },
      { target: PEAK_RPS,   duration: '1m'  },
      { target: NORMAL_RPS, duration: '30s' } ]
  : [ { target: NORMAL_RPS, duration: '3m'  },   // warmup
      { target: PEAK_RPS,   duration: '2m'  },   // dốc lên 5x
      { target: PEAK_RPS,   duration: `${PEAK_MIN}m` },  // giữ tải cao điểm
      { target: NORMAL_RPS, duration: '3m'  } ]; // quan sát scale-in

export const options = {
  scenarios: {
    b2b_traffic: {
      executor: 'ramping-arrival-rate',   // giữ ĐÚNG req/s, không phụ thuộc thời gian phản hồi
      startRate: NORMAL_RPS,
      timeUnit: '1s',
      preAllocatedVUs: 200,
      maxVUs: 2000,
      stages,
    },
  },
  thresholds: {
    // Ngưỡng lấy nguyên văn từ ràng buộc #4 của yêu cầu.
    'http_req_duration{expected_response:true}': ['p(95)<2000'],
    'http_req_failed':   ['rate<0.01'],
    'business_error_rate': ['rate<0.01'],
    'create_order_latency': ['p(95)<2000'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  discardResponseBodies: false,
};

// Đơn đã tạo trong lần chạy này, dùng làm nguồn cho request đọc.
const createdIds = [];

function createOrder() {
  const payload = JSON.stringify({
    customer_code: CUSTOMERS[randomIntBetween(0, CUSTOMERS.length - 1)],
    items: Array.from({ length: randomIntBetween(1, 3) }, () => ({
      sku: SKUS[randomIntBetween(0, SKUS.length - 1)],
      quantity: randomIntBetween(1, 10),
    })),
  });

  const res = http.post(`${BASE_URL}/api/orders`, payload, {
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': uuidv4() },
    tags: { name: 'POST /api/orders' },
  });

  createLatency.add(res.timings.duration);

  // 202 Accepted là kết quả ĐÚNG. Nếu API trả 200/201 nghĩa là nó đang báo
  // "thành công" trước khi worker commit — vi phạm ràng buộc #5.
  const ok = check(res, {
    'tạo đơn trả 202 Accepted': r => r.status === 202,
    'phản hồi có order_id':     r => r.status === 202 && !!r.json('order_id'),
    'trạng thái ban đầu là PENDING': r => r.status === 202 && r.json('status') === 'PENDING',
  });

  if (ok) {
    orderCreated.add(1);
    if (createdIds.length < 500) createdIds.push(res.json('order_id'));
  } else {
    orderRejected.add(1);
  }
  businessError.add(!ok);
}

function readOrder() {
  if (createdIds.length === 0) return listOrders();
  const id = createdIds[randomIntBetween(0, createdIds.length - 1)];
  const res = http.get(`${BASE_URL}/api/orders/${id}`, { tags: { name: 'GET /api/orders/:id' } });
  const ok = check(res, { 'đọc đơn trả 200': r => r.status === 200 });
  businessError.add(!ok);
}

function listOrders() {
  const res = http.get(`${BASE_URL}/api/orders?limit=20`, { tags: { name: 'GET /api/orders' } });
  const ok = check(res, { 'liệt kê đơn trả 200': r => r.status === 200 });
  businessError.add(!ok);
}

export default function () {
  const roll = Math.random();
  if (roll < MIX.create)                    createOrder();
  else if (roll < MIX.create + MIX.read)    readOrder();
  else                                      listOrders();
}

export function handleSummary(data) {
  const m = data.metrics;
  const get = (name, stat) => (m[name] && m[name].values[stat] != null ? m[name].values[stat] : NaN);
  const p95   = get('http_req_duration', 'p(95)');
  const fail  = get('http_req_failed', 'rate') * 100;
  const total = get('http_reqs', 'count');
  const rps   = get('http_reqs', 'rate');

  const verdict = (p95 < 2000 && fail < 1) ? 'ĐẠT' : 'KHÔNG ĐẠT';
  const report = `
=====================================================================
 TEST B1 — Chịu tải 5x  (ràng buộc #4)
=====================================================================
 Cấu hình      : ${NORMAL_RPS} req/s bình thường -> ${PEAK_RPS} req/s cao điểm
 Tổng request  : ${Math.round(total).toLocaleString()}   (${rps.toFixed(1)} req/s trung bình)
 Đơn đã tạo    : ${Math.round(get('orders_created', 'count') || 0).toLocaleString()}
 Đơn bị từ chối: ${Math.round(get('orders_rejected', 'count') || 0).toLocaleString()}

 p95 toàn bộ   : ${p95.toFixed(0)} ms      (ngưỡng < 2000 ms)
 p95 tạo đơn   : ${get('create_order_latency', 'p(95)').toFixed(0)} ms
 p99 toàn bộ   : ${get('http_req_duration', 'p(99)').toFixed(0)} ms
 Tỷ lệ lỗi     : ${fail.toFixed(3)} %       (ngưỡng < 1 %)

 KẾT LUẬN      : ${verdict}
=====================================================================
`;
  console.log(report);
  return {
    'stdout': report,
    'evidence/b1-load-test.json': JSON.stringify(data, null, 2),
    'evidence/b1-load-test.txt': report,
  };
}
