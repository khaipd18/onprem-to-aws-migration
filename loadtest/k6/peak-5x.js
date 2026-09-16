// TEST CASE B1 - ràng buộc #4 của yêu cầu:
//   "Đáp ứng tải gấp 5 lần mức bình thường đã thống nhất trong 30 phút,
//    p95 không quá 2 giây và tỷ lệ lỗi kỹ thuật không quá 1%."
//
//   k6 run -e BASE_URL=http://<alb-dns> --out json=b1-result.json loadtest/peak-5x.js
//
// Ngưỡng dưới đây được viết ĐÚNG bằng câu chữ của yêu cầu. k6 thoát với mã != 0
// nếu vi phạm, nên kết quả là bằng chứng đạt/không đạt, không phải ý kiến.
//
// Chạy load generator từ MỘT EC2 RIÊNG (c6i.large trở lên), đừng chạy từ laptop
// qua internet - độ trễ đường truyền sẽ làm hỏng số đo p95.
import { sleep } from 'k6';
import { browse, createOrder } from './lib.js';

const PEAK = Number(__ENV.PEAK_RATE || 250);   // 5 x 50 req/s

export const options = {
  scenarios: {
    peak: {
      executor: 'ramping-arrival-rate',
      startRate: Number(__ENV.BASE_RATE || 50),
      timeUnit: '1s',
      preAllocatedVUs: 200,
      maxVUs: 1500,
      stages: [
        { target: 50,   duration: '2m'  },   // ổn định ở mức bình thường
        { target: PEAK, duration: '1m'  },   // spike - đây là lúc ASG phải kịp
        { target: PEAK, duration: '30m' },   // giữ 5x trong 30 phút
        { target: 50,   duration: '2m'  },   // hạ nhiệt
      ],
    },
  },
  thresholds: {
    // Đúng nguyên văn ngưỡng của yêu cầu.
    'http_req_duration{name:POST /orders}': [
      { threshold: 'p(95)<2000', abortOnFail: false },
    ],
    technical_error_rate: [
      { threshold: 'rate<0.01', abortOnFail: false },
    ],
    checks: ['rate>0.99'],
  },
};

export default function () {
  createOrder();
  if (Math.random() < 0.25) browse();
  sleep(0.05);
}

export function handleSummary(data) {
  const p95 = data.metrics['http_req_duration{name:POST /orders}']
    ?.values?.['p(95)'] ?? data.metrics.http_req_duration.values['p(95)'];
  const errRate = data.metrics.technical_error_rate?.values?.rate ?? 0;
  const verdict = (p95 < 2000 && errRate < 0.01) ? 'ĐẠT' : 'KHÔNG ĐẠT';

  const report = [
    '',
    '='.repeat(58),
    ' TEST B1 - Tải cao điểm 5x trong 30 phút (ràng buộc #4)',
    '='.repeat(58),
    ` p95 POST /orders   : ${p95.toFixed(0)} ms      (ngưỡng < 2000 ms)`,
    ` tỷ lệ lỗi kỹ thuật : ${(errRate * 100).toFixed(3)} %   (ngưỡng < 1 %)`,
    ` đơn được tiếp nhận : ${data.metrics.orders_accepted?.values?.count ?? 0}`,
    ` bị từ chối 503     : ${data.metrics.orders_rejected_503?.values?.count ?? 0}`,
    ` tổng số request    : ${data.metrics.http_reqs.values.count}`,
    '-'.repeat(58),
    ` KẾT LUẬN: ${verdict}`,
    '='.repeat(58),
    '',
  ].join('\n');

  return {
    stdout: report,
    'b1-summary.json': JSON.stringify(data, null, 2),
    'b1-verdict.txt': report,
  };
}
