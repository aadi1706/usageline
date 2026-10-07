from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.db import get_db
from app.models import Plan
from app.schemas import PlanCreate, PlanOut

router = APIRouter(prefix="/plans", tags=["plans"])


@router.post("", response_model=PlanOut, status_code=201)
def create_plan(body: PlanCreate, db: Session = Depends(get_db)):
    plan = Plan(**body.model_dump())
    db.add(plan)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "plan name already exists")
    return plan


@router.get("", response_model=list[PlanOut])
def list_plans(db: Session = Depends(get_db)):
    return db.scalars(select(Plan).order_by(Plan.id)).all()
