"""Add inbound expiry_time and DB uniqueness

Revision ID: 7c8d1f7f2c1a
Revises: 1c93f4c57f4f
Create Date: 2026-04-02 16:45:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "7c8d1f7f2c1a"
down_revision: Union[str, Sequence[str], None] = "1c93f4c57f4f"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _deduplicate_inbounds() -> None:
    bind = op.get_bind()
    subscriptions = sa.table(
        "subscriptions",
        sa.column("inbound_id", sa.Integer()),
    )
    inbounds = sa.table(
        "inbounds",
        sa.column("id", sa.Integer()),
    )
    duplicate_groups = bind.execute(
        sa.text(
            """
            SELECT server_id, xui_inbound_id, MIN(id) AS keep_id
            FROM inbounds
            GROUP BY server_id, xui_inbound_id
            HAVING COUNT(*) > 1
            """
        )
    ).mappings()

    for group in duplicate_groups:
        duplicate_ids = bind.execute(
            sa.text(
                """
                SELECT id
                FROM inbounds
                WHERE server_id = :server_id
                  AND xui_inbound_id = :xui_inbound_id
                  AND id <> :keep_id
                ORDER BY id
                """
            ),
            group,
        ).scalars().all()

        if not duplicate_ids:
            continue

        bind.execute(
            sa.update(subscriptions)
            .where(subscriptions.c.inbound_id.in_(duplicate_ids))
            .values(inbound_id=group["keep_id"])
        )
        bind.execute(
            sa.delete(inbounds).where(inbounds.c.id.in_(duplicate_ids))
        )


def upgrade() -> None:
    op.add_column(
        "inbounds",
        sa.Column(
            "expiry_time",
            sa.BigInteger(),
            nullable=False,
            server_default="0",
        ),
    )
    op.alter_column("inbounds", "expiry_time", server_default=None)

    _deduplicate_inbounds()
    op.create_unique_constraint(
        "uq_inbounds_server_id_xui_inbound_id",
        "inbounds",
        ["server_id", "xui_inbound_id"],
    )


def downgrade() -> None:
    op.drop_constraint(
        "uq_inbounds_server_id_xui_inbound_id",
        "inbounds",
        type_="unique",
    )
    op.drop_column("inbounds", "expiry_time")
