from datetime import datetime

from pydantic import BaseModel, ConfigDict


class SpendCategoryItem(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    name: str
    icon: str | None = None
    color: str | None = None
    position: int = 0
    builtin: bool = False


class CategoryMapItem(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    raw_category: str
    canonical_category: str
    source: str = "manual"


class CategoryConfig(BaseModel):
    """The caller's full category taxonomy + raw→canonical map - the relational successor to the
    `categories.v1` blob. `updated_at` is the max row timestamp, the last-write-wins watermark the client
    compares against its local sync watermark."""

    categories: list[SpendCategoryItem] = []
    maps: list[CategoryMapItem] = []
    updated_at: datetime | None = None


class CategoryConfigUpsert(BaseModel):
    categories: list[SpendCategoryItem] = []
    maps: list[CategoryMapItem] = []
