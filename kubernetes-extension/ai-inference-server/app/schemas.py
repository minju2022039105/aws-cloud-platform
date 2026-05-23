from pydantic import BaseModel


class PredictRequest(BaseModel):
    country_code: float
    rule_code: float
    uri_len: float
    path_entropy: float
    args_entropy: float


class PredictResponse(BaseModel):
    anomaly: int
    score: float
