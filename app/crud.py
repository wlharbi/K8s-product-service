from datetime import datetime, timezone
from decimal import Decimal
from typing import Optional

from sqlalchemy import func, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.exceptions import ConflictError, InsufficientStockError, NotFoundError
from app.models import Product
from app.schemas import ProductCreate, ProductUpdate


def create_product(db: Session, data: ProductCreate) -> Product:
    product = Product(**data.model_dump())
    db.add(product)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise ConflictError(f"Product with SKU '{data.sku}' already exists")
    db.refresh(product)
    return product


def get_product(db: Session, product_id: int) -> Product:
    product = db.get(Product, product_id)
    if product is None:
        raise NotFoundError(f"Product {product_id} not found")
    return product


def list_products(
    db: Session,
    *,
    q: Optional[str] = None,
    is_active: Optional[bool] = None,
    min_price: Optional[Decimal] = None,
    max_price: Optional[Decimal] = None,
    limit: int = 20,
    offset: int = 0,
) -> tuple[list[Product], int]:
    stmt = select(Product)
    if q:
        like = f"%{q}%"
        stmt = stmt.where(or_(Product.name.ilike(like), Product.sku.ilike(like)))
    if is_active is not None:
        stmt = stmt.where(Product.is_active == is_active)
    if min_price is not None:
        stmt = stmt.where(Product.price >= min_price)
    if max_price is not None:
        stmt = stmt.where(Product.price <= max_price)

    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    items = db.scalars(stmt.order_by(Product.id).limit(limit).offset(offset)).all()
    return list(items), total


def update_product(db: Session, product_id: int, data: ProductUpdate) -> Product:
    product = get_product(db, product_id)
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(product, field, value)
    db.commit()
    db.refresh(product)
    return product


def delete_product(db: Session, product_id: int) -> None:
    product = get_product(db, product_id)
    db.delete(product)
    db.commit()


def adjust_stock(db: Session, product_id: int, delta: int) -> Product:
    """Atomic stock change: the UPDATE only applies if stock stays >= 0,
    so concurrent requests cannot oversell."""
    result = db.execute(
        update(Product)
        .where(Product.id == product_id, Product.stock + delta >= 0)
        .values(stock=Product.stock + delta, updated_at=datetime.now(timezone.utc))
    )
    if result.rowcount == 0:
        db.rollback()
        get_product(db, product_id)  # raises NotFoundError if missing
        raise InsufficientStockError("Insufficient stock for this adjustment")
    db.commit()
    product = db.get(Product, product_id)
    db.refresh(product)
    return product
