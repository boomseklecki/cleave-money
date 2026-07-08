from fastapi import APIRouter, Query

from app.integrations.statements.institutions import search
from app.schemas.institution import InstitutionResponse

router = APIRouter(tags=["institutions"])


@router.get("/institutions", response_model=list[InstitutionResponse])
async def list_institutions(
    q: str = Query("", description="case-insensitive name search"),
    limit: int = Query(50, ge=1, le=100),
) -> list[InstitutionResponse]:
    """Search the OFX-importable institution directory (Intuit FIDIR Web Connect banks). Reference data - 
    no user scope."""
    return [InstitutionResponse(name=i.name, domain=i.domain, home_url=i.home_url)
            for i in search(q, limit)]
