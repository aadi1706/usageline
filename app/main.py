from fastapi import FastAPI

from app.routers import invoices, plans, tenants, usage

app = FastAPI(title="Usageline", version="0.1.0")


@app.get("/health", tags=["health"])
def health():
    return {"status": "ok"}


app.include_router(plans.router)
app.include_router(tenants.router)
app.include_router(usage.router)
app.include_router(invoices.router)
