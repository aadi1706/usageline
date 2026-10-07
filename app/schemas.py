from datetime import datetime, timezone

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


def _to_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


class PlanCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    base_fee_cents: int = Field(ge=0)
    included_units: int = Field(ge=0)
    unit_price_cents: int = Field(ge=0)


class PlanOut(PlanCreate):
    model_config = ConfigDict(from_attributes=True)
    id: int


class TenantCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    plan_id: int


class TenantOut(TenantCreate):
    model_config = ConfigDict(from_attributes=True)
    id: int
    created_at: datetime


class UsageEventCreate(BaseModel):
    metric: str = Field(min_length=1, max_length=100)
    quantity: int = Field(gt=0)
    timestamp: datetime | None = None

    @field_validator("timestamp")
    @classmethod
    def normalize_timestamp(cls, v):
        return _to_utc(v) if v else v


class UsageEventOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    tenant_id: int
    metric: str
    quantity: int
    timestamp: datetime


class InvoiceCreate(BaseModel):
    period_start: datetime
    period_end: datetime

    @field_validator("period_start", "period_end")
    @classmethod
    def normalize(cls, v):
        return _to_utc(v)

    @model_validator(mode="after")
    def check_order(self):
        if self.period_end <= self.period_start:
            raise ValueError("period_end must be after period_start")
        return self


class InvoiceOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    tenant_id: int
    plan_id: int
    period_start: datetime
    period_end: datetime
    total_units: int
    billable_units: int
    base_fee_cents: int
    usage_charge_cents: int
    total_cents: int
    created_at: datetime
