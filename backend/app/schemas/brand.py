from pydantic import BaseModel, Field


class BrandOverrideItem(BaseModel):
    """One merchant to logo mapping: a `pattern` matched against a merchant/note (plain substring, `*`/`?`
    glob, or a `/regex/`), a display `name`, and the website `domain` that serves the favicon (empty = name
    only, no logo). Matching runs on-device; the server just stores the rule."""
    pattern: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=120)
    domain: str = Field(default="", max_length=255)


class BrandOverridesUpdate(BaseModel):
    """Replace-all payload: the full desired catalog in match order (the first matching pattern wins, so list a
    broad pattern below a more specific one)."""
    items: list[BrandOverrideItem]
