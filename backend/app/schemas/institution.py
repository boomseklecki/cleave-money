from pydantic import BaseModel


class InstitutionResponse(BaseModel):
    """A bank/credit institution that supports OFX file (Web Connect) export - for the in-app
    "banks you can import from" directory. Sourced from Intuit's FIDIR list."""
    name: str
    domain: str
    home_url: str
