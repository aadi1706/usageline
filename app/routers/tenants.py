from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.db import get_db
from app.models import Plan, Tenant
from app.schemas import TenantCreate, TenantOut

router = APIRouter(prefix="/tenants", tags=["tenants"])


@router.post("", response_model=TenantOut, status_code=201)
def create_tenant(body: TenantCreate, db: Session = Depends(get_db)):
    if db.get(Plan, body.plan_id) is None:
        raise HTTPException(404, "plan not found")
    tenant = Tenant(**body.model_dump())
    db.add(tenant)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "tenant name already exists")
    return tenant


@router.get("", response_model=list[TenantOut])
def list_tenants(db: Session = Depends(get_db)):
    return db.scalars(select(Tenant).order_by(Tenant.id)).all()


@router.get("/{tenant_id}", response_model=TenantOut)
def get_tenant(tenant_id: int, db: Session = Depends(get_db)):
    tenant = db.get(Tenant, tenant_id)
    if tenant is None:
        raise HTTPException(404, "tenant not found")
    return tenant
