from fastapi import Depends, FastAPI, HTTPException
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.db import get_db
from app.metrics import metrics_middleware
from app.metrics import router as metrics_router
from app.routers import invoices, plans, tenants, usage

app = FastAPI(title="Usageline", version="0.1.0")
app.middleware("http")(metrics_middleware)


@app.get("/health", tags=["health"])
def health():
    return {"status": "ok"}


@app.get("/ready", tags=["health"])
def ready(db: Session = Depends(get_db)):
    try:
        db.execute(text("SELECT 1"))
    except Exception:
        raise HTTPException(503, "database unavailable") from None
    return {"status": "ready"}


app.include_router(metrics_router)
app.include_router(plans.router)
app.include_router(tenants.router)
app.include_router(usage.router)
app.include_router(invoices.router)
