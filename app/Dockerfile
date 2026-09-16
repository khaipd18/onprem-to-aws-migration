# Một image duy nhất cho cả 3 vai trò (web / app / worker); phân biệt bằng
# biến môi trường TIER và command. Giữ 1 image giúp CI/CD đơn giản và bảo đảm
# các tier luôn cùng phiên bản code.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1

WORKDIR /srv

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . /srv/

# Chạy bằng user thường, không phải root.
RUN useradd --create-home --uid 10001 appuser && chown -R appuser /srv
USER appuser

EXPOSE 8080
CMD ["uvicorn", "appapi.main:app", "--host", "0.0.0.0", "--port", "8080"]
