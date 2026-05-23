from fastapi import FastAPI
from .schemas import PredictRequest, PredictResponse
from .model_loader import load_model

app = FastAPI(title="AI Inference Server")
model, scaler = load_model()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/predict", response_model=PredictResponse)
def predict(request: PredictRequest):
    features = [[
        request.country_code,
        request.rule_code,
        request.uri_len,
        request.path_entropy,
        request.args_entropy
    ]]
    scaled = scaler.transform(features)
    score = model.decision_function(scaled)[0]
    anomaly = int(model.predict(scaled)[0] == -1)
    return {"anomaly": anomaly, "score": round(float(score), 4)}
