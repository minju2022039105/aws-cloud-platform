import os
import joblib

MODEL_PATH = os.getenv("MODEL_PATH", "/models/isolation_forest_model.pkl")
SCALER_PATH = os.getenv("SCALER_PATH", "/models/scaler.pkl")


def load_model():
    model = joblib.load(MODEL_PATH)
    scaler = joblib.load(SCALER_PATH)
    return model, scaler
