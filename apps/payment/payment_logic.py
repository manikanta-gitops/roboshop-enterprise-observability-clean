def count_items(items):
    return sum(item.get('qty', 0) for item in items if item.get('sku') != 'SHIP')


def has_shipping(items):
    return any(item.get('sku') == 'SHIP' for item in items)


def is_valid_cart(cart):
    items = cart.get('items', []) or []
    return bool(cart.get('total', 0)) and has_shipping(items)
