from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.models import Tenant, UsageEvent
from app.schemas import UsageEventCreate, UsageEventOut

router = APIRouter(prefix="/tenants/{tenant_id}/usage", tags=["usage"])


def _require_tenant(db: Session, tenant_id: int) -> Tenant:
    tenant = db.get(Tenant, tenant_id)
    if tenant is None:
        raise HTTPException(404, "tenant not found")
    return tenant


@router.post("", response_model=UsageEventOut, status_code=201)
def record_usage(tenant_id: int, body: UsageEventCreate, db: Session = Depends(get_db)):
    _require_tenant(db, tenant_id)
    data = body.model_dump(exclude_none=True)
    event = UsageEvent(tenant_id=tenant_id, **data)
    db.add(event)
    db.commit()
    return event


@router.get("", response_model=list[UsageEventOut])
def list_usage(tenant_id: int, db: Session = Depends(get_db)):
    _require_tenant(db, tenant_id)
    stmt = select(UsageEvent).where(UsageEvent.tenant_id == tenant_id).order_by(UsageEvent.id)
    return db.scalars(stmt).all()
