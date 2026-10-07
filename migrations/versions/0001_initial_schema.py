"""initial schema

Revision ID: 0001
Revises:
"""
import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "plans",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("name", sa.String(100), nullable=False, unique=True),
        sa.Column("base_fee_cents", sa.Integer, nullable=False),
        sa.Column("included_units", sa.Integer, nullable=False),
        sa.Column("unit_price_cents", sa.Integer, nullable=False),
    )
    op.create_table(
        "tenants",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("name", sa.String(100), nullable=False, unique=True),
        sa.Column("plan_id", sa.Integer, sa.ForeignKey("plans.id"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "usage_events",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("tenant_id", sa.Integer, sa.ForeignKey("tenants.id"), nullable=False),
        sa.Column("metric", sa.String(100), nullable=False),
        sa.Column("quantity", sa.Integer, nullable=False),
        sa.Column("timestamp", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_usage_events_tenant_id", "usage_events", ["tenant_id"])
    op.create_index("ix_usage_events_timestamp", "usage_events", ["timestamp"])
    op.create_table(
        "invoices",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("tenant_id", sa.Integer, sa.ForeignKey("tenants.id"), nullable=False),
        sa.Column("plan_id", sa.Integer, sa.ForeignKey("plans.id"), nullable=False),
        sa.Column("period_start", sa.DateTime(timezone=True), nullable=False),
        sa.Column("period_end", sa.DateTime(timezone=True), nullable=False),
        sa.Column("total_units", sa.Integer, nullable=False),
        sa.Column("billable_units", sa.Integer, nullable=False),
        sa.Column("base_fee_cents", sa.Integer, nullable=False),
        sa.Column("usage_charge_cents", sa.Integer, nullable=False),
        sa.Column("total_cents", sa.Integer, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_invoices_tenant_id", "invoices", ["tenant_id"])


def downgrade():
    op.drop_table("invoices")
    op.drop_table("usage_events")
    op.drop_table("tenants")
    op.drop_table("plans")
