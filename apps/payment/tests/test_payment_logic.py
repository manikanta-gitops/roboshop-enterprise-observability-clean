from payment_logic import count_items, has_shipping, is_valid_cart


def test_count_items_excludes_shipping():
    assert count_items([{"sku": "ABC", "qty": 2}, {"sku": "SHIP", "qty": 1}]) == 2


def test_shipping_is_required():
    assert has_shipping([{"sku": "SHIP", "qty": 1}])
    assert not has_shipping([{"sku": "ABC", "qty": 1}])


def test_cart_validation():
    assert is_valid_cart({"total": 100, "items": [{"sku": "SHIP", "qty": 1}]})
    assert not is_valid_cart({"total": 0, "items": [{"sku": "SHIP", "qty": 1}]})
    assert not is_valid_cart({"total": 100, "items": [{"sku": "ABC", "qty": 1}]})
