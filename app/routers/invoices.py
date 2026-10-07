from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.models import Invoice, Plan, Tenant, UsageEvent
from app.schemas import InvoiceCreate, InvoiceOut

router = APIRouter(tags=["invoices"])


@router.post("/tenants/{tenant_id}/invoices", response_model=InvoiceOut, status_code=201)
def generate_invoice(tenant_id: int, body: InvoiceCreate, db: Session = Depends(get_db)):
    tenant = db.get(Tenant, tenant_id)
    if tenant is None:
        raise HTTPException(404, "tenant not found")
    plan = db.get(Plan, tenant.plan_id)

    total_units = db.scalar(
        select(func.coalesce(func.sum(UsageEvent.quantity), 0)).where(
            UsageEvent.tenant_id == tenant_id,
            UsageEvent.timestamp >= body.period_start,
            UsageEvent.timestamp < body.period_end,
        )
    )
    billable_units = max(0, total_units - plan.included_units)
    usage_charge = billable_units * plan.unit_price_cents

    invoice = Invoice(
        tenant_id=tenant_id,
        plan_id=plan.id,
        period_start=body.period_start,
        period_end=body.period_end,
        total_units=total_units,
        billable_units=billable_units,
        base_fee_cents=plan.base_fee_cents,
        usage_charge_cents=usage_charge,
        total_cents=plan.base_fee_cents + usage_charge,
    )
    db.add(invoice)
    db.commit()
    return invoice


@router.get("/tenants/{tenant_id}/invoices", response_model=list[InvoiceOut])
def list_invoices(tenant_id: int, db: Session = Depends(get_db)):
    if db.get(Tenant, tenant_id) is None:
        raise HTTPException(404, "tenant not found")
    stmt = select(Invoice).where(Invoice.tenant_id == tenant_id).order_by(Invoice.id)
    return db.scalars(stmt).all()


@router.get("/invoices/{invoice_id}", response_model=InvoiceOut)
def get_invoice(invoice_id: int, db: Session = Depends(get_db)):
    invoice = db.get(Invoice, invoice_id)
    if invoice is None:
        raise HTTPException(404, "invoice not found")
    return invoice
