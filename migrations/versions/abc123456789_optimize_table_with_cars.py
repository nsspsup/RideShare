"""optimize table with cars

Revision ID: abc123456789
Revises: b4e5b1a90605
Create Date: 2025-07-16 21:30:00.000000
"""
from alembic import op
import sqlalchemy as sa

revision = 'abc123456789'
down_revision = 'b4e5b1a90605'
branch_labels = None
depends_on = None

def upgrade():
    # Remove car-related columns from User
    with op.batch_alter_table('user') as batch_op:
        batch_op.drop_column('car_type')
        batch_op.drop_column('car_model')
        batch_op.drop_column('year_of_make')
        batch_op.drop_column('seats')
        batch_op.drop_column('fuel_type')
        batch_op.drop_column('avg_consumption')


    # Create Car table
    op.create_table(
        'car',
        sa.Column('id', sa.Integer(), primary_key=True),
        sa.Column('user_id', sa.Integer(), sa.ForeignKey('user.id', ondelete='CASCADE'), nullable=False),
        sa.Column('make', sa.String(length=64), nullable=False),
        sa.Column('model', sa.String(length=64), nullable=False),
        sa.Column('year_of_make', sa.Integer()),
        sa.Column('fuel_type', sa.String(length=20)),
        sa.Column('avg_consumption', sa.Float()),
        sa.Column('seats', sa.Integer(), nullable=False),
        sa.Column('plate', sa.String(length=20), nullable=False),
    )


def downgrade():
    op.drop_table('car')

    with op.batch_alter_table('trip') as batch_op:
        batch_op.drop_column('departure_time')

    with op.batch_alter_table('user') as batch_op:
        batch_op.add_column(sa.Column('car_type', sa.String(length=100)))
        batch_op.add_column(sa.Column('car_model', sa.String(length=100)))
        batch_op.add_column(sa.Column('year_of_make', sa.Integer()))
        batch_op.add_column(sa.Column('seats', sa.Integer()))
        batch_op.add_column(sa.Column('fuel_type', sa.String(length=20)))
        batch_op.add_column(sa.Column('avg_consumption', sa.Float()))
