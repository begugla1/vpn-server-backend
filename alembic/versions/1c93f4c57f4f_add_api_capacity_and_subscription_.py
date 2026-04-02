"""Add server capacity and single-subscription rule

Revision ID: 1c93f4c57f4f
Revises: 5272b505389d
Create Date: 2026-04-02 13:30:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "1c93f4c57f4f"
down_revision: Union[str, Sequence[str], None] = "5272b505389d"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "servers",
        sa.Column(
            "max_subscriptions",
            sa.Integer(),
            nullable=False,
            server_default="150",
        ),
    )
    op.alter_column("servers", "max_subscriptions", server_default=None)
    op.create_unique_constraint(
        "uq_subscriptions_user_id",
        "subscriptions",
        ["user_id"],
    )


def downgrade() -> None:
    op.drop_constraint(
        "uq_subscriptions_user_id",
        "subscriptions",
        type_="unique",
    )
    op.drop_column("servers", "max_subscriptions")
