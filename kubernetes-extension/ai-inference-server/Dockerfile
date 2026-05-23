FROM python:3.12-slim

WORKDIR /app

# 빌드 컨텍스트: 레포 루트 (docker build -f kubernetes-extension/ai-inference-server/Dockerfile .)
COPY kubernetes-extension/ai-inference-server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY kubernetes-extension/ai-inference-server/app/ ./app/
COPY ai/models/isolation_forest_model.pkl /models/isolation_forest_model.pkl
COPY ai/models/scaler.pkl /models/scaler.pkl

EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
