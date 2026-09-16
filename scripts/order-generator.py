#!/usr/bin/env python3
"""Bơm đơn hàng liên tục — mô phỏng "hệ thống nguồn vẫn phát sinh giao dịch".

Ràng buộc #2 nói rõ hệ thống nguồn vẫn nhận và cập nhật đơn trong lúc chuyển
đổi, downtime tối đa 15 phút, không mất và không trùng giao dịch đã xác nhận.
Không có công cụ này thì cutover chỉ là copy một database đứng yên — không
chứng minh được gì.

Cách dùng khi diễn tập cutover:

    # cửa sổ 1 — bơm đơn vào hệ thống NGUỒN, ghi lại mọi đơn đã gửi
    python3 scripts/order-generator.py --url http://localhost:18080 \\
        --rate 2 --duration 900 --ledger evidence/cutover-ledger.jsonl

    # cửa sổ 2 — chạy cutover (bật maintenance page, chờ CDC về 0, đổi endpoint)

    # sau cutover — đối chiếu sổ cái với database ĐÍCH
    python3 scripts/order-generator.py --verify evidence/cutover-ledger.jsonl \\
        --url http://localhost:8080

`--ledger` là mấu chốt: mỗi đơn gửi đi được ghi lại kèm idempotency key và
thời điểm, nên sau cutover có thể đối chiếu từng dòng thay vì chỉ so tổng số.
"""
from __future__ import annotations

import argparse
import json
import random
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from collections import Counter
from datetime import datetime, timezone

CUSTOMERS = [f"CUST-{i:04d}" for i in range(1, 61)]
SKUS = [f"{p}-{v:03d}" for p in ("BRG", "MTR", "VLV", "PMP", "GBX", "BLT", "SNS", "PLC")
        for v in range(1, 7)]

_stop = threading.Event()


def _handle_signal(_sig, _frame):
    print("\nnhận tín hiệu dừng, đang kết thúc...", file=sys.stderr)
    _stop.set()


def post_order(url: str, timeout: float) -> tuple[int, dict, str]:
    key = f"gen-{uuid.uuid4()}"
    body = {
        "customer_code": random.choice(CUSTOMERS),
        "items": [{"sku": random.choice(SKUS), "quantity": random.randint(1, 8)}
                  for _ in range(random.randint(1, 3))],
    }
    req = urllib.request.Request(
        f"{url}/api/orders", method="POST",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Idempotency-Key": key},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read() or b"{}"), key
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read() or b"{}"), key
        except Exception:  # noqa: BLE001
            return exc.code, {}, key
    except Exception as exc:  # noqa: BLE001
        return 0, {"error": str(exc)}, key


def generate(args) -> int:
    ledger = open(args.ledger, "a", buffering=1) if args.ledger else None
    stats: Counter[str] = Counter()
    deadline = time.time() + args.duration
    interval = 1.0 / args.rate if args.rate > 0 else 0
    sent = 0

    print(f"bơm đơn vào {args.url} — {args.rate} đơn/giây trong {args.duration}s")
    if ledger:
        print(f"ghi sổ cái vào {args.ledger}")

    while not _stop.is_set() and time.time() < deadline:
        started = time.time()
        status, payload, key = post_order(args.url, args.timeout)
        # 0 = không kết nối được (đang trong cửa sổ downtime của cutover)
        bucket = "network_error" if status == 0 else str(status)
        stats[bucket] += 1
        sent += 1

        if ledger:
            ledger.write(json.dumps({
                "t": datetime.now(timezone.utc).isoformat(),
                "idempotency_key": key,
                "http": status,
                "order_id": payload.get("order_id"),
                "status": payload.get("status"),
            }) + "\n")

        if sent % 20 == 0:
            summary = " ".join(f"{k}={v}" for k, v in sorted(stats.items()))
            left = int(deadline - time.time())
            print(f"  đã gửi {sent:>6}  còn {left:>4}s  [{summary}]", flush=True)

        pause = interval - (time.time() - started)
        if pause > 0:
            _stop.wait(pause)

    if ledger:
        ledger.close()
    print(f"\ntổng cộng {sent} request")
    for code, n in sorted(stats.items()):
        print(f"  {code:>14}: {n}")
    accepted = stats["202"] + stats["201"] + stats["200"]
    print(f"\nsố đơn được TIẾP NHẬN: {accepted}")
    print(f"số request THẤT BẠI  : {sent - accepted}"
          f"  <- đây là phần rơi vào cửa sổ downtime")
    return 0


def verify(args) -> int:
    """Đối chiếu sổ cái với hệ thống đích sau cutover."""
    entries = [json.loads(line) for line in open(args.verify) if line.strip()]
    accepted = [e for e in entries if e.get("order_id") and e["http"] in (200, 201, 202)]
    print(f"sổ cái: {len(entries)} request, {len(accepted)} đơn được tiếp nhận")
    print(f"đối chiếu với {args.url} ...\n")

    found: Counter[str] = Counter()
    missing: list[str] = []

    for i, entry in enumerate(accepted, 1):
        oid = entry["order_id"]
        try:
            with urllib.request.urlopen(f"{args.url}/api/orders/{oid}",
                                        timeout=args.timeout) as resp:
                data = json.loads(resp.read())
            found[data.get("status", "?")] += 1
            if data.get("status") not in ("CONFIRMED", "CANCELLED"):
                missing.append(oid)
        except urllib.error.HTTPError as exc:
            found[f"http_{exc.code}"] += 1
            missing.append(oid)
        except Exception as exc:  # noqa: BLE001
            found[f"error"] += 1
            missing.append(oid)
        if i % 50 == 0:
            print(f"  ... đã kiểm tra {i}/{len(accepted)}", flush=True)

    print("\nkết quả đối chiếu:")
    for status, n in sorted(found.items()):
        print(f"  {status:>12}: {n}")

    lost = len(missing)
    print(f"\nsố đơn ĐÃ TIẾP NHẬN nhưng KHÔNG tìm thấy ở đích: {lost}")
    if lost:
        print("  (10 mã đầu tiên)")
        for oid in missing[:10]:
            print(f"    {oid}")
    print(f"\nKẾT LUẬN: {'ĐẠT — không mất giao dịch' if lost == 0 else 'KHÔNG ĐẠT'}")
    return 0 if lost == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://localhost:8080")
    ap.add_argument("--rate", type=float, default=2.0, help="số đơn mỗi giây")
    ap.add_argument("--duration", type=int, default=300, help="chạy trong bao nhiêu giây")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--ledger", help="file jsonl ghi lại mọi đơn đã gửi")
    ap.add_argument("--verify", help="đối chiếu sổ cái này với --url rồi thoát")
    args = ap.parse_args()

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    return verify(args) if args.verify else generate(args)


if __name__ == "__main__":
    sys.exit(main())
