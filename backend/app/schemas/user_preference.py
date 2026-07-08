from datetime import datetime

from pydantic import BaseModel, ConfigDict


class PreferenceUpsert(BaseModel):
    value: str  # opaque JSON string; the app owns/versions the shape


class PreferenceResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    key: str
    value: str
    updated_at: datetime
