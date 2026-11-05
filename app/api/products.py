from decimal import Decimal
from typing import Optional

from fastapi import APIRouter, Depends, Query, Response, status
from sqlalchemy.orm import Session

from app import crud
from app.database import get_db
from app.schemas import Page, ProductCreate, ProductOut, ProductUpdate, StockAdjustment

router = APIRouter(prefix="/products", tags=["products"])


@router.post("", response_model=ProductOut, status_code=status.HTTP_201_CREATED)
def create_product(
    data: ProductCreate, response: Response, db: Session = Depends(get_db)
):
    product = crud.create_product(db, data)
    response.headers["Location"] = f"/products/{product.id}"
    return product


@router.get("", response_model=Page)
def list_products(
    q: Optional[str] = Query(None, description="Search name or SKU"),
    is_active: Optional[bool] = None,
    min_price: Optional[Decimal] = Query(None, ge=0),
    max_price: Optional[Decimal] = Query(None, ge=0),
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db),
):
    items, total = crud.list_products(
        db,
        q=q,
        is_active=is_active,
        min_price=min_price,
        max_price=max_price,
        limit=limit,
        offset=offset,
    )
    return Page(items=items, total=total, limit=limit, offset=offset)


@router.get("/{product_id}", response_model=ProductOut)
def get_product(product_id: int, db: Session = Depends(get_db)):
    return crud.get_product(db, product_id)


@router.patch("/{product_id}", response_model=ProductOut)
def update_product(product_id: int, data: ProductUpdate, db: Session = Depends(get_db)):
    return crud.update_product(db, product_id, data)


@router.delete("/{product_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_product(product_id: int, db: Session = Depends(get_db)):
    crud.delete_product(db, product_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{product_id}/stock", response_model=ProductOut)
def adjust_stock(
    product_id: int, data: StockAdjustment, db: Session = Depends(get_db)
):
    return crud.adjust_stock(db, product_id, data.delta)
